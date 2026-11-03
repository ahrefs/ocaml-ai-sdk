//! The VM: a QuickJS context with a `host` global, driven by the frame loop. Eval and message
//! frames are handled strictly in order; after each one the promise job queue is drained.

use crate::{
    envelope::{decode_incoming, encode_outgoing, Incoming, Outgoing, Payload, TOO_LARGE_RESULT},
    frame::{read_frame, write_frame, FrameError},
};
use rquickjs::{
    context::{
        intrinsic::{
            DOMException, Date, Eval, Json, MapSet, Performance, Promise, Proxy, RegExp, RegExpCompiler, TypedArrays,
            WeakRef,
        },
        EvalOptions,
    },
    function::Func,
    ArrayBuffer, Coerced, Context, Ctx, Error, Function, Object, Runtime, Value,
};
use std::{
    cell::RefCell,
    io::{Read, Write},
    rc::Rc,
};

const BOOTSTRAP: &str = include_str!("../js/bootstrap.js");

/// Replaces `Math.random` unless `--allow-random`.
const DISABLE_RANDOM: &str =
    r#"Math.random=function random(){throw new Error("Math.random is disabled in this sandbox")};Object.freeze(Math);"#;

/// Longest `log` text, further limited by the frame cap.
const MAX_LOG_BYTES: usize = 64 * 1024;

/// Every intrinsic except `Date` and `Performance`.
type Base = (
    Eval,
    RegExpCompiler,
    RegExp,
    Json,
    Proxy,
    MapSet,
    TypedArrays,
    Promise,
    WeakRef,
    DOMException,
);
type WithClock = (Base, (Date, Performance));

/// Creates the context. Without `allow_clock` there is no `Date` and no `Performance`.
pub fn create_context(runtime: &Runtime, allow_clock: bool) -> Result<Context, Error> {
    match allow_clock {
        true => Context::custom::<WithClock>(runtime),
        false => Context::custom::<Base>(runtime),
    }
}

/// The frames the runner writes to stdout; one place for the cap and the failure policy.
pub struct Out {
    sink: RefCell<Box<dyn Write>>,
    max: u32,
}

impl Out {
    pub fn new(sink: impl Write + 'static, max: u32) -> Rc<Self> {
        Rc::new(Self {
            sink: RefCell::new(Box::new(sink)),
            max,
        })
    }

    /// Writes `frame` unless it exceeds the cap (then nothing is written). An i/o failure ends
    /// the process: nobody is listening.
    pub fn send(&self, frame: &Outgoing) -> Result<(), FrameError> {
        match write_frame(&mut *self.sink.borrow_mut(), &encode_outgoing(frame), self.max) {
            Err(FrameError::Io(_)) => std::process::exit(1),
            result => result,
        }
    }

    /// Sends a fatal error, truncating its text to fit the cap at a UTF-8 boundary.
    pub fn send_error(&self, message: &str) {
        let mut end = message.len().min(4096);
        loop {
            while !message.is_char_boundary(end) {
                end -= 1;
            }
            match self.send(&Outgoing::Error {
                message: message[..end].to_string(),
            }) {
                Err(FrameError::TooLarge { len, max }) if end > 0 => {
                    end = end.saturating_sub((len - u64::from(max)) as usize);
                }
                _ => return,
            }
        }
    }

    /// A `log` frame, truncated to fit; dropped when it cannot be written.
    pub fn log(&self, level: &str, text: &str) {
        let limit = MAX_LOG_BYTES.min((self.max / 2) as usize);
        let end = (0..=limit.min(text.len()))
            .rev()
            .find(|&i| text.is_char_boundary(i))
            .unwrap_or(0);
        let _ = self.send(&Outgoing::Log {
            level: level.to_string(),
            text: text[..end].to_string(),
        });
    }
}

/// The helpers the bootstrap hands back; they are not reachable from scripts.
pub struct Api<'js> {
    deliver: Function<'js>,
    norm: Function<'js>,
    size: Function<'js>,
    max: u32,
}

/// A value that may cross the boundary, after `norm`: a string (lone surrogates already replaced by
/// U+FFFD, so it is valid UTF-8), an ArrayBuffer or a Uint8Array. The class is tested before
/// anything is read, so no exception is left pending in the engine.
fn payload_of(value: &Value<'_>) -> Option<Payload> {
    if let Some(s) = value.as_string() {
        return s.to_string().ok().map(Payload::Text);
    }
    let object = value.as_object()?;
    // SAFETY (both arms): the bytes are copied before any JavaScript can run again.
    if let Some(buffer) = object.as_array_buffer() {
        return unsafe { buffer.as_bytes() }.map(|b| Payload::Bytes(b.to_vec()));
    }
    let array = object.as_typed_array::<u8>()?;
    unsafe { array.as_bytes() }.map(|b| Payload::Bytes(b.to_vec()))
}

fn eval_options(filename: &str) -> EvalOptions {
    let mut options = EvalOptions::default();
    // Global, sloppy-mode script, like `(0, eval)(code)`.
    options.strict = false;
    options.filename = Some(filename.to_string());
    options
}

/// Evaluates the bootstrap: installs `host` and `console` and returns the runner's helpers.
pub fn install<'js>(ctx: &Ctx<'js>, out: &Rc<Out>) -> Result<Api<'js>, String> {
    let post_out = Rc::clone(out);
    let post = Func::from(move |value: Value<'js>| -> i32 {
        match payload_of(&value) {
            None => 1,
            Some(Payload::Text(t)) if t.len() > post_out.max as usize => 2,
            Some(Payload::Bytes(b)) if b.len() > post_out.max as usize => 2,
            Some(payload) => match post_out.send(&Outgoing::Message(payload)) {
                Ok(()) => 0,
                Err(_) => 2,
            },
        }
    });
    let log_out = Rc::clone(out);
    let log = Func::from(move |level: String, text: String| log_out.log(&level, &text));
    let eval_as = Func::from(
        |ctx: Ctx<'js>, code: String, filename: String| -> rquickjs::Result<Value<'js>> {
            ctx.eval_with_options(code, eval_options(&filename))
        },
    );
    let setup: Function = ctx
        .eval_with_options(BOOTSTRAP, eval_options("<bootstrap>"))
        .map_err(|e| js_error(ctx, e))?;
    let api: Object = setup
        .call((post, log, eval_as, out.max))
        .map_err(|e| js_error(ctx, e))?;
    let get = |name: &str| api.get::<_, Function>(name).map_err(|e| js_error(ctx, e));
    Ok(Api {
        deliver: get("deliver")?,
        norm: get("norm")?,
        size: get("size")?,
        max: out.max,
    })
}

/// Replaces `Math.random` with a function that throws, and freezes `Math`.
pub fn disable_random(ctx: &Ctx<'_>) -> Result<(), String> {
    ctx.eval_with_options::<(), _>(DISABLE_RANDOM, eval_options("<init>"))
        .map_err(|e| js_error(ctx, e))
}

/// The exception pending on `ctx` as text: `Name: message`, then the stack when there is one.
fn describe_exception(ctx: &Ctx<'_>) -> String {
    let exception = ctx.catch();
    let text = |object: &Object<'_>, key: &str| object.get::<_, Option<String>>(key).ok().flatten().unwrap_or_default();
    match exception.as_object() {
        Some(object) if object.is_error() => {
            let (name, message, stack) = (text(object, "name"), text(object, "message"), text(object, "stack"));
            let head = match message.is_empty() {
                true => name,
                false => format!("{name}: {message}"),
            };
            match stack.trim_end() {
                "" => head,
                frames => format!("{head}\n{frames}"),
            }
        }
        _ => exception
            .get::<Coerced<String>>()
            .map(|c| c.0)
            .unwrap_or_else(|_| "<exception that cannot be converted to a string>".to_string()),
    }
}

fn js_error(ctx: &Ctx<'_>, error: Error) -> String {
    match error.is_exception() {
        true => describe_exception(ctx),
        false => error.to_string(),
    }
}

/// Runs queued promise jobs until there are none. A job that throws is dropped, like an
/// unhandled rejection.
fn drain_jobs(ctx: &Ctx<'_>) {
    while ctx.execute_pending_job() {}
}

fn convert_result<'js>(api: &Api<'js>, value: Value<'js>) -> Result<Option<Payload>, String> {
    const NOT_TRANSFERABLE: &str = "result is not transferable";
    match value.is_undefined() || value.is_null() {
        true => Ok(None),
        false => {
            // The size is checked before any copy: the cap would reject the frame anyway.
            let size: f64 = api
                .size
                .call((value.clone(),))
                .map_err(|_| NOT_TRANSFERABLE.to_string())?;
            match size {
                size if size < 0.0 => Err(NOT_TRANSFERABLE.to_string()),
                size if size > f64::from(api.max) => Err(TOO_LARGE_RESULT.to_string()),
                _ => {
                    let normalized: Value = api.norm.call((value,)).map_err(|_| NOT_TRANSFERABLE.to_string())?;
                    payload_of(&normalized)
                        .map(Some)
                        .ok_or_else(|| NOT_TRANSFERABLE.to_string())
                }
            }
        }
    }
}

/// Evaluates one script. `Err` is a failure of the runtime itself (not a JS exception).
fn handle_eval<'js>(ctx: &Ctx<'js>, api: &Api<'js>, code: String) -> Result<Result<Option<Payload>, String>, String> {
    let result = match ctx.eval_with_options::<Value, _>(code, eval_options("<eval>")) {
        Ok(value) => convert_result(api, value),
        Err(error) if error.is_exception() => Err(describe_exception(ctx)),
        Err(error) => return Err(format!("the VM failed: {error}")),
    };
    drain_jobs(ctx);
    Ok(result)
}

fn handle_message<'js>(ctx: &Ctx<'js>, api: &Api<'js>, data: Payload) -> Result<(), String> {
    let fail = |e: Error| format!("cannot deliver a message: {e}");
    let value: Value = match data {
        Payload::Text(text) => rquickjs::String::from_str(ctx.clone(), &text)
            .map_err(fail)?
            .into_value(),
        Payload::Bytes(bytes) => ArrayBuffer::new(ctx.clone(), bytes).map_err(fail)?.into_value(),
    };
    match api.deliver.call::<_, ()>((value,)) {
        Ok(()) => {}
        Err(error) if error.is_exception() => return Err(format!("the VM failed: {}", describe_exception(ctx))),
        Err(error) => return Err(fail(error)),
    }
    drain_jobs(ctx);
    Ok(())
}

fn send_eval_result(out: &Out, id: u64, result: Result<Option<Payload>, String>) {
    let frame = Outgoing::EvalResult { id, result };
    match out.send(&frame) {
        Ok(()) => {}
        Err(_) => {
            let _ = out.send(&Outgoing::EvalResult {
                id,
                result: Err(TOO_LARGE_RESULT.to_string()),
            });
        }
    }
}

/// The frame loop. `Ok` on clean EOF; `Err` carries the message for the `error` frame.
pub fn serve<'js>(ctx: &Ctx<'js>, api: &Api<'js>, input: &mut impl Read, out: &Out, max: u32) -> Result<(), String> {
    loop {
        let payload = match read_frame(input, max).map_err(|e| e.to_string())? {
            Some(payload) => payload,
            None => return Ok(()),
        };
        match decode_incoming(&payload).map_err(|e| e.to_string())? {
            Incoming::Eval { id, code } => {
                let result = handle_eval(ctx, api, code)?;
                send_eval_result(out, id, result);
            }
            Incoming::Message(data) => handle_message(ctx, api, data)?,
        }
    }
}
