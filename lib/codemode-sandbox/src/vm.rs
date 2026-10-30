//! Drives one QuickJS VM through one script, the way pi-codemode's `runtime/vm.ts` does: the
//! prelude (see `prelude.js`) builds the script's environment and keeps the promises of pending
//! host calls; this module only supplies its native `bridge`, runs the script and feeds it the
//! host's results. QuickJS has no event loop, so the VM runs only while the promise job queue is
//! non-empty and otherwise waits in a blocking read for the next result.

use crate::protocol::{self, parse_result};
use rquickjs::{context::EvalOptions, function::Rest, Ctx, Error, Function, Object, Value};
use serde_json::{json, Value as Json};
use std::{cell::Cell, io::BufRead, rc::Rc};

const PRELUDE: &str = include_str!("prelude.js");

/// What the host sends first: pi's `VmStartData`, minus what only a worker needs.
pub struct Start {
    pub code: String,
    pub tools_json: String,
    pub globals_json: String,
    pub store_json: String,
    /// Can only lower the `--memory-limit-mb` limit.
    pub memory_limit_bytes: Option<u64>,
}

impl Start {
    pub fn parse(line: &str) -> Result<Self, String> {
        let data: Json = serde_json::from_str(line).map_err(|e| format!("invalid start data: {e}"))?;
        if data.get("deterministic").is_some_and(|d| !d.is_null()) {
            return Err("deterministic mode is not supported".to_string());
        }
        let code = data
            .get("code")
            .and_then(Json::as_str)
            .ok_or("start data without a string `code`")?;
        let field = |name: &str, default: &str| match data.get(name) {
            Some(value) if !value.is_null() => value.to_string(),
            _ => default.to_string(),
        };
        Ok(Self {
            code: code.to_string(),
            tools_json: field("tools", "[]"),
            globals_json: field("globals", "[]"),
            store_json: field("store", "{}"),
            memory_limit_bytes: data.get("memoryLimitBytes").and_then(Json::as_u64),
        })
    }
}

/// Global, sloppy-mode code, like quickjs-wasi's `evalCode`: scripts may rely on it, for example
/// assigning to a frozen built-in silently fails instead of throwing.
fn eval_options(filename: &str) -> EvalOptions {
    let mut options = EvalOptions::default();
    options.strict = false;
    options.filename = Some(filename.to_string());
    options
}

/// A string argument of the bridge. Strings that do not convert (unpaired surrogates) become a
/// placeholder instead of failing the whole script.
fn string_arg(value: Option<&Value<'_>>) -> Option<String> {
    let string = value?.as_string()?;
    Some(
        string
            .to_string()
            .unwrap_or_else(|_| "<string that is not valid UTF-8>".to_string()),
    )
}

/// Handles one `bridge(kind, a, b, c)` call from the prelude: the messages of
/// `WorkerToHostMessage`, with `undefined` fields left out.
fn handle_bridge(args: &[Value<'_>], finished: &Cell<bool>) -> Result<(), String> {
    let arg = |i: usize| string_arg(args.get(i));
    let text = |i: usize| arg(i).unwrap_or_default();
    let kind = arg(0).ok_or("bridge called without a kind")?;
    let message = match kind.as_str() {
        "call" | "global" => {
            let id = args
                .get(1)
                .and_then(|v| v.as_int().map(f64::from).or_else(|| v.as_float()))
                .ok_or("call without an id")?;
            let id = if id.fract() == 0.0 { json!(id as i64) } else { json!(id) };
            let target = if kind == "call" { "tool" } else { "global" };
            let mut message = json!({ "type": "call", "id": id, "target": target, "name": text(2) });
            if let Some(json_args) = arg(3) {
                message["args"] = json!(json_args);
            }
            message
        }
        "output" => {
            let item = match arg(1).as_deref() {
                Some("image") => json!({ "type": "image", "data": text(2), "mimeType": text(3) }),
                Some("console") => json!({ "type": "text", "text": text(2), "console": true }),
                _ => json!({ "type": "text", "text": text(2) }),
            };
            json!({ "type": "output", "item": item })
        }
        "done" => {
            let ok = args.get(1).and_then(Value::as_bool).ok_or("done without ok")?;
            let message = if ok {
                let mut message =
                    json!({ "type": "done", "ok": true, "writes": arg(3).unwrap_or_else(|| "[]".to_string()) });
                if let Some(value) = arg(2) {
                    message["value"] = json!(value);
                }
                message
            } else {
                json!({ "type": "done", "ok": false, "error": text(2) })
            };
            finished.set(true);
            message
        }
        other => return Err(format!("unknown bridge kind {other:?}")),
    };
    protocol::send(&message)
}

/// An exception as JSON `{name, message, stack}`, with the stack prefixed by `name: message` like V8.
fn describe_exception(ctx: &Ctx<'_>) -> String {
    let exception = ctx.catch();
    let object = exception.as_object();
    let text = |key: &str| {
        object
            .and_then(|o| o.get::<_, Option<String>>(key).ok().flatten())
            .unwrap_or_default()
    };
    let (name, message, stack) = (text("name"), text("message"), text("stack"));
    let head = if message.is_empty() {
        name.clone()
    } else {
        format!("{name}: {message}")
    };
    let stack = match stack.trim_end() {
        "" => head,
        frames => format!("{head}\n{frames}"),
    };
    json!({ "name": name, "message": message, "stack": stack }).to_string()
}

fn js_error(ctx: &Ctx<'_>, error: Error) -> String {
    if error.is_exception() {
        describe_exception(ctx)
    } else {
        error.to_string()
    }
}

/// Runs the script to its `done` message. Returns an error for failures of the VM itself, which
/// the caller reports as `crash`.
pub fn run(ctx: &Ctx<'_>, start: &Start, input: &mut impl BufRead) -> Result<(), String> {
    let finished = Rc::new(Cell::new(false));
    let bridge = {
        let finished = Rc::clone(&finished);
        Function::new(ctx.clone(), move |args: Rest<Value<'_>>| {
            if let Err(message) = handle_bridge(&args.0, &finished) {
                protocol::send_crash(&message);
                std::process::exit(1);
            }
        })
        .map_err(|e| js_error(ctx, e))?
    };

    let prelude: Function = ctx
        .eval_with_options(PRELUDE, eval_options("codemode-prelude.js"))
        .map_err(|e| js_error(ctx, e))?;
    let api: Object = prelude
        .call((
            bridge,
            start.tools_json.as_str(),
            start.globals_json.as_str(),
            start.store_json.as_str(),
        ))
        .map_err(|e| js_error(ctx, e))?;
    let get = |name: &str| api.get::<_, Function>(name).map_err(|e| js_error(ctx, e));
    let (settle, run, stalled) = (get("settle")?, get("run")?, get("stalled")?);

    // The prefix shares the first line with the script so reported line numbers match.
    let wrapped = format!("(async (tools, console) => {{{}\n}})", start.code);
    let script: Function = match ctx.eval_with_options(wrapped, eval_options("codemode.js")) {
        Ok(script) => script,
        Err(error) if error.is_exception() => {
            let error = describe_exception(ctx);
            return protocol::send(&json!({ "type": "done", "ok": false, "error": error }));
        }
        Err(error) => return Err(error.to_string()),
    };

    // Run queued jobs, then fail a script that waits on nothing that can ever resume it.
    let drain = || -> Result<(), String> {
        while ctx.execute_pending_job() {}
        stalled.call::<_, bool>(()).map(|_| ()).map_err(|e| js_error(ctx, e))
    };

    run.call::<_, ()>((script,)).map_err(|e| js_error(ctx, e))?;
    drain()?;
    while !finished.get() {
        let line = protocol::read_line(input)
            .map_err(|e| format!("cannot read from stdin: {e}"))?
            .ok_or("host closed stdin before the script finished")?;
        let result = parse_result(&line)?;
        settle
            .call::<_, ()>((result.id, result.ok, result.payload, result.properties))
            .map_err(|e| js_error(ctx, e))?;
        drain()?;
    }
    Ok(())
}
