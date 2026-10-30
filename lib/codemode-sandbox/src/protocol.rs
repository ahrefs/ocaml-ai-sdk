//! The wire format: pi-codemode's `WorkerToHostMessage` and `HostToWorkerMessage`, one JSON object
//! per line. Values a script produced (`args`, `value`, `payload`, `error`, `writes`) are already
//! JSON text and travel as strings; an absent field means `undefined`.

use serde_json::Value;
use std::io::{self, BufRead, Write};

/// Writes `message` as one line on stdout. The protocol owns stdout: nothing else prints there.
pub fn send(message: &Value) -> Result<(), String> {
    let mut line = message.to_string().into_bytes();
    line.push(b'\n');
    let mut out = io::stdout().lock();
    out.write_all(&line)
        .and_then(|()| out.flush())
        .map_err(|e| format!("cannot write to stdout: {e}"))
}

/// Reports a failure of the VM itself and expects the host to stop it.
pub fn send_crash(message: &str) {
    let _ = send(&serde_json::json!({ "type": "crash", "message": message }));
}

/// Reads the next line, without its terminator. `None` at end of input.
pub fn read_line(input: &mut impl BufRead) -> io::Result<Option<String>> {
    let mut line = String::new();
    match input.read_line(&mut line)? {
        0 => Ok(None),
        _ => Ok(Some(line.trim_end_matches(['\n', '\r']).to_string())),
    }
}

/// A `result` message from the host, settling the call `id`.
pub struct CallResult {
    pub id: f64,
    pub ok: bool,
    pub payload: Option<String>,
    pub properties: Option<String>,
}

pub fn parse_result(line: &str) -> Result<CallResult, String> {
    let message: Value = serde_json::from_str(line).map_err(|e| format!("invalid JSON from host: {e}"))?;
    match message.get("type").and_then(Value::as_str) {
        Some("result") => {}
        other => return Err(format!("unexpected message type from host: {other:?}")),
    }
    let string_field = |name: &str| message.get(name).and_then(Value::as_str).map(str::to_string);
    Ok(CallResult {
        id: message
            .get("id")
            .and_then(Value::as_f64)
            .ok_or("result without a numeric id")?,
        ok: message
            .get("ok")
            .and_then(Value::as_bool)
            .ok_or("result without a boolean ok")?,
        payload: string_field("payload"),
        properties: string_field("properties"),
    })
}
