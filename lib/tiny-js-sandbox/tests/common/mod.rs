//! A dev harness that drives the real binary the way an embedder does: minicbor-encoded
//! frames in, decoded frames out.
#![allow(dead_code)]

use std::{
    io::Write,
    process::{Child, ChildStdin, ChildStdout, Command, ExitStatus, Stdio},
};
use tiny_js_sandbox::{
    envelope::{decode_outgoing, encode_incoming, Incoming, Outgoing, Payload},
    frame::{read_frame, write_frame},
};

pub const BIN: &str = env!("CARGO_BIN_EXE_tiny-js-sandbox");

pub struct Runner {
    pub child: Child,
    stdin: Option<ChildStdin>,
    stdout: ChildStdout,
    max: u32,
    next_id: u64,
}

impl Runner {
    /// Spawns with `--sandbox=<sandbox>`, `--memory-limit-mb=64` (unless `extra` sets it) and `extra`.
    pub fn spawn(sandbox: &str, extra: &[&str]) -> Self {
        let default_memory: &[&str] = match extra.iter().any(|a| a.starts_with("--memory-limit-mb")) {
            true => &[],
            false => &["--memory-limit-mb=64"],
        };
        let mut child = Command::new(BIN)
            .arg(format!("--sandbox={sandbox}"))
            .args(default_memory)
            .args(extra)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().unwrap();
        Self {
            child,
            stdin,
            stdout,
            max: 1 << 30,
            next_id: 1,
        }
    }

    /// Spawns and checks the `hello` frame.
    pub fn start(sandbox: &str, extra: &[&str]) -> Self {
        let mut runner = Self::spawn(sandbox, extra);
        assert_eq!(runner.recv(), Some(Outgoing::Hello { proto: 1 }));
        runner
    }

    pub fn send_raw(&mut self, bytes: &[u8]) {
        let stdin = self.stdin.as_mut().unwrap();
        stdin.write_all(bytes).unwrap();
        stdin.flush().unwrap();
    }

    pub fn send_payload(&mut self, payload: &[u8]) {
        let mut framed = Vec::new();
        write_frame(&mut framed, payload, u32::MAX).unwrap();
        self.send_raw(&framed);
    }

    pub fn send(&mut self, frame: &Incoming) {
        self.send_payload(&encode_incoming(frame));
    }

    /// Sends an eval frame and returns its id.
    pub fn send_eval(&mut self, code: &str) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        self.send(&Incoming::Eval {
            id,
            code: code.to_string(),
        });
        id
    }

    pub fn close_stdin(&mut self) {
        self.stdin = None;
    }

    /// The next frame; `None` at EOF.
    pub fn recv(&mut self) -> Option<Outgoing> {
        let payload = read_frame(&mut self.stdout, self.max).expect("well-formed frame")?;
        Some(decode_outgoing(&payload).expect("valid runner frame"))
    }

    /// Everything up to and including the `eval_result` for `id`; returns the frames before it
    /// and the result.
    pub fn until_result(&mut self, id: u64) -> (Vec<Outgoing>, Result<Option<Payload>, String>) {
        let mut before = vec![];
        loop {
            match self.recv().expect("runner ended before the result") {
                Outgoing::EvalResult { id: got, result } if got == id => return (before, result),
                other => before.push(other),
            }
        }
    }

    /// Evaluates `code` and returns its result (discarding frames in between).
    pub fn eval(&mut self, code: &str) -> Result<Option<Payload>, String> {
        let id = self.send_eval(code);
        self.until_result(id).1
    }

    /// Evaluates `code` expecting a text value.
    pub fn eval_text(&mut self, code: &str) -> String {
        match self.eval(code) {
            Ok(Some(Payload::Text(t))) => t,
            other => panic!("expected text from {code:?}, got {other:?}"),
        }
    }

    /// Closes stdin and waits for the exit status.
    pub fn finish(mut self) -> ExitStatus {
        self.stdin = None;
        self.child.wait().unwrap()
    }

    /// Waits for the process to end (stdin untouched).
    pub fn wait(mut self) -> ExitStatus {
        self.child.wait().unwrap()
    }
}

/// Text payload helper.
pub fn text(s: &str) -> Payload {
    Payload::Text(s.to_string())
}
