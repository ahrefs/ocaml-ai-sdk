//! The frame envelopes of PROTOCOL.md, encoded and decoded with `minicbor`'s token reader.
//!
//! Every envelope is a flat map with text keys whose values are unsigned integers, text, bytes,
//! booleans or null. The decoder reads exactly that and rejects anything else (containers, tags,
//! floats, indefinite lengths, ...) at the first token, so it never recurses and the work it does
//! is bounded by the frame size.

use minicbor::{data::Type, encode::Write, Decoder, Encoder};
use std::fmt;

/// Largest unsigned integer accepted: ids stay exact in JavaScript.
pub const MAX_UINT: u64 = (1 << 53) - 1;
/// No envelope has more than 4 keys; anything above is rejected before it is read.
const MAX_KEYS: u64 = 4;
/// Protocol version announced by `hello`.
pub const PROTO: u64 = 1;

/// Application data: what `host.post`, `host.onmessage` and eval results carry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Payload {
    Text(String),
    Bytes(Vec<u8>),
}

/// Frames the parent sends.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Incoming {
    Eval { id: u64, code: String },
    Message(Payload),
}

/// Frames the runner sends.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outgoing {
    Hello {
        proto: u64,
    },
    /// `Ok(None)` is a `null` value.
    EvalResult {
        id: u64,
        result: Result<Option<Payload>, String>,
    },
    Message(Payload),
    Log {
        level: String,
        text: String,
    },
    Error {
        message: String,
    },
}

/// A CBOR or envelope violation, described for the `error` frame.
#[derive(Debug, PartialEq, Eq)]
pub struct ProtocolError(pub String);

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

fn violation<T>(message: impl Into<String>) -> Result<T, ProtocolError> {
    Err(ProtocolError(message.into()))
}

enum Value {
    Uint(u64),
    Text(String),
    Bytes(Vec<u8>),
    Bool(bool),
    Null,
}

impl Value {
    fn kind(&self) -> &'static str {
        match self {
            Self::Uint(_) => "uint",
            Self::Text(_) => "text",
            Self::Bytes(_) => "bytes",
            Self::Bool(_) => "bool",
            Self::Null => "null",
        }
    }
}

/// Longest peer-supplied text echoed in a violation message, in characters.
const MAX_ECHO_CHARS: usize = 64;

/// A peer-supplied string, quoted and cut short, for use in error messages (the peer controls it,
/// up to the frame cap).
fn shown(text: &str) -> String {
    match text.char_indices().nth(MAX_ECHO_CHARS) {
        Some((end, _)) => format!("{:?}...", &text[..end]),
        None => format!("{text:?}"),
    }
}

/// The decoded entries of one envelope, consumed key by key; leftovers are unknown keys.
struct Fields {
    entries: Vec<(String, Value)>,
}

impl Fields {
    fn take(&mut self, key: &str) -> Result<Value, ProtocolError> {
        match self.entries.iter().position(|(k, _)| k == key) {
            Some(i) => Ok(self.entries.swap_remove(i).1),
            None => violation(format!("missing key {key:?}")),
        }
    }

    fn wrong_type<T>(key: &str, expected: &str, got: &Value) -> Result<T, ProtocolError> {
        violation(format!("key {key:?} must be {expected}, got {}", got.kind()))
    }

    fn uint(&mut self, key: &str) -> Result<u64, ProtocolError> {
        match self.take(key)? {
            Value::Uint(n) => Ok(n),
            other => Self::wrong_type(key, "uint", &other),
        }
    }

    fn text(&mut self, key: &str) -> Result<String, ProtocolError> {
        match self.take(key)? {
            Value::Text(s) => Ok(s),
            other => Self::wrong_type(key, "text", &other),
        }
    }

    fn boolean(&mut self, key: &str) -> Result<bool, ProtocolError> {
        match self.take(key)? {
            Value::Bool(b) => Ok(b),
            other => Self::wrong_type(key, "bool", &other),
        }
    }

    fn payload(&mut self, key: &str) -> Result<Payload, ProtocolError> {
        match self.take(key)? {
            Value::Text(s) => Ok(Payload::Text(s)),
            Value::Bytes(b) => Ok(Payload::Bytes(b)),
            other => Self::wrong_type(key, "text or bytes", &other),
        }
    }

    fn optional_payload(&mut self, key: &str) -> Result<Option<Payload>, ProtocolError> {
        match self.take(key)? {
            Value::Text(s) => Ok(Some(Payload::Text(s))),
            Value::Bytes(b) => Ok(Some(Payload::Bytes(b))),
            Value::Null => Ok(None),
            other => Self::wrong_type(key, "text, bytes or null", &other),
        }
    }

    /// Fails when keys other than the ones taken remain.
    fn finish(self) -> Result<(), ProtocolError> {
        match self.entries.first() {
            Some((key, _)) => violation(format!("unknown key {}", shown(key))),
            None => Ok(()),
        }
    }
}

fn cbor_error(e: minicbor::decode::Error) -> ProtocolError {
    ProtocolError(format!("invalid CBOR: {e}"))
}

fn read_value(d: &mut Decoder<'_>) -> Result<Value, ProtocolError> {
    match d.datatype().map_err(cbor_error)? {
        Type::U8 | Type::U16 | Type::U32 | Type::U64 => match d.u64().map_err(cbor_error)? {
            n if n > MAX_UINT => violation("integer above 2^53 - 1"),
            n => Ok(Value::Uint(n)),
        },
        Type::String => Ok(Value::Text(d.str().map_err(cbor_error)?.to_owned())),
        Type::Bytes => Ok(Value::Bytes(d.bytes().map_err(cbor_error)?.to_vec())),
        Type::Bool => Ok(Value::Bool(d.bool().map_err(cbor_error)?)),
        Type::Null => {
            d.null().map_err(cbor_error)?;
            Ok(Value::Null)
        }
        Type::Undefined => violation("undefined is not allowed"),
        Type::Simple => violation("simple values other than false, true and null are not allowed"),
        Type::F16 | Type::F32 | Type::F64 => violation("floats are not allowed"),
        Type::Tag => violation("tags are not allowed"),
        Type::Array | Type::ArrayIndef | Type::Map | Type::MapIndef => {
            violation("containers are not allowed as values")
        }
        Type::BytesIndef | Type::StringIndef => violation("indefinite-length items are not allowed"),
        Type::Int | Type::I8 | Type::I16 | Type::I32 | Type::I64 => violation("negative integers are not allowed"),
        Type::Break | Type::Unknown(_) => violation("unexpected CBOR item"),
    }
}

/// Reads one frame payload as a flat map and returns the frame type `t` with the other entries.
fn read_envelope(payload: &[u8]) -> Result<(String, Fields), ProtocolError> {
    let mut d = Decoder::new(payload);
    let count = match d.datatype().map_err(cbor_error)? {
        Type::Map => d.map().map_err(cbor_error)?.unwrap_or(0),
        Type::MapIndef => return violation("indefinite-length items are not allowed"),
        _ => return violation("a frame must be a map"),
    };
    if count > MAX_KEYS {
        return violation(format!("map with {count} keys; no frame has more than {MAX_KEYS}"));
    }
    let mut entries: Vec<(String, Value)> = Vec::new();
    for _ in 0..count {
        let key = match d.datatype().map_err(cbor_error)? {
            Type::String => d.str().map_err(cbor_error)?.to_owned(),
            _ => return violation("map keys must be text"),
        };
        if entries.iter().any(|(k, _)| *k == key) {
            return violation(format!("duplicate key {}", shown(&key)));
        }
        entries.push((key, read_value(&mut d)?));
    }
    if d.position() != payload.len() {
        return violation("trailing bytes after the frame");
    }
    let mut fields = Fields { entries };
    let t = fields.text("t")?;
    Ok((t, fields))
}

/// Decodes a frame the parent sent.
pub fn decode_incoming(payload: &[u8]) -> Result<Incoming, ProtocolError> {
    let (t, mut f) = read_envelope(payload)?;
    let frame = match t.as_str() {
        "eval" => Incoming::Eval {
            id: f.uint("id")?,
            code: f.text("code")?,
        },
        "message" => Incoming::Message(f.payload("data")?),
        other => return violation(format!("unknown frame type {}", shown(other))),
    };
    f.finish()?;
    Ok(frame)
}

/// Decodes a frame the runner sent (for tests and embedders written in Rust).
pub fn decode_outgoing(payload: &[u8]) -> Result<Outgoing, ProtocolError> {
    let (t, mut f) = read_envelope(payload)?;
    let frame = match t.as_str() {
        "hello" => Outgoing::Hello {
            proto: f.uint("proto")?,
        },
        "eval_result" => {
            let id = f.uint("id")?;
            let result = match f.boolean("ok")? {
                true => Ok(f.optional_payload("value")?),
                false => Err(f.text("error")?),
            };
            Outgoing::EvalResult { id, result }
        }
        "message" => Outgoing::Message(f.payload("data")?),
        "log" => Outgoing::Log {
            level: f.text("level")?,
            text: f.text("text")?,
        },
        "error" => Outgoing::Error {
            message: f.text("message")?,
        },
        other => return violation(format!("unknown frame type {}", shown(other))),
    };
    f.finish()?;
    Ok(frame)
}

type Enc = Encoder<Vec<u8>>;

fn build(f: impl FnOnce(&mut Enc) -> Result<(), minicbor::encode::Error<std::convert::Infallible>>) -> Vec<u8> {
    let mut e = Encoder::new(Vec::new());
    f(&mut e).expect("encoding into a Vec cannot fail");
    e.into_writer()
}

fn put_payload<W: Write>(e: &mut Encoder<W>, payload: &Payload) -> Result<(), minicbor::encode::Error<W::Error>> {
    match payload {
        Payload::Text(s) => e.str(s),
        Payload::Bytes(b) => e.bytes(b),
    }
    .map(|_| ())
}

/// Encodes a runner frame; `"t"` comes first, integers use the shortest form.
pub fn encode_outgoing(frame: &Outgoing) -> Vec<u8> {
    build(|e| {
        match frame {
            Outgoing::Hello { proto } => {
                e.map(2)?.str("t")?.str("hello")?.str("proto")?.u64(*proto)?;
            }
            Outgoing::EvalResult { id, result } => {
                e.map(4)?.str("t")?.str("eval_result")?.str("id")?.u64(*id)?.str("ok")?;
                match result {
                    Ok(value) => {
                        e.bool(true)?.str("value")?;
                        match value {
                            Some(p) => put_payload(e, p)?,
                            None => {
                                e.null()?;
                            }
                        }
                    }
                    Err(error) => {
                        e.bool(false)?.str("error")?.str(error)?;
                    }
                }
            }
            Outgoing::Message(p) => {
                e.map(2)?.str("t")?.str("message")?.str("data")?;
                put_payload(e, p)?;
            }
            Outgoing::Log { level, text } => {
                e.map(3)?
                    .str("t")?
                    .str("log")?
                    .str("level")?
                    .str(level)?
                    .str("text")?
                    .str(text)?;
            }
            Outgoing::Error { message } => {
                e.map(2)?.str("t")?.str("error")?.str("message")?.str(message)?;
            }
        }
        Ok(())
    })
}

/// Encodes a parent frame (used by tests and Rust embedders).
pub fn encode_incoming(frame: &Incoming) -> Vec<u8> {
    build(|e| {
        match frame {
            Incoming::Eval { id, code } => {
                e.map(3)?
                    .str("t")?
                    .str("eval")?
                    .str("id")?
                    .u64(*id)?
                    .str("code")?
                    .str(code)?;
            }
            Incoming::Message(p) => {
                e.map(2)?.str("t")?.str("message")?.str("data")?;
                put_payload(e, p)?;
            }
        }
        Ok(())
    })
}
