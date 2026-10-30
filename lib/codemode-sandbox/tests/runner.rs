//! Runs the binary the way a host does: start data on the first stdin line, results on the
//! following ones, messages on stdout.

use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
};

const BIN: &str = env!("CARGO_BIN_EXE_ai-sdk-quickjs-runner");

struct Runner {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
}

impl Runner {
    fn spawn(sandbox: &str) -> Self {
        let mut child = Command::new(BIN)
            .args([&format!("--sandbox={sandbox}"), "--memory-limit-mb=64"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Self { child, stdin, stdout }
    }

    fn send(&mut self, message: &Value) {
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(stdin, "{message}").unwrap();
        stdin.flush().unwrap();
    }

    fn start(&mut self, code: &str, tools: &[&str]) {
        let tools: Vec<Value> = tools
            .iter()
            .map(|n| json!({ "name": n, "jsName": n, "description": "" }))
            .collect();
        self.send(&json!({ "code": code, "tools": tools, "globals": [], "store": {} }));
    }

    fn recv(&mut self) -> Option<Value> {
        let mut line = String::new();
        match self.stdout.read_line(&mut line).unwrap() {
            0 => None,
            _ => Some(serde_json::from_str(&line).unwrap()),
        }
    }

    /// Messages up to and including the first of type `done` or `crash`.
    fn until_end(&mut self) -> Vec<Value> {
        let mut messages = vec![];
        while let Some(message) = self.recv() {
            let end = matches!(message["type"].as_str(), Some("done" | "crash"));
            messages.push(message);
            if end {
                break;
            }
        }
        messages
    }
}

fn run_script(code: &str) -> Vec<Value> {
    let mut runner = Runner::spawn("none");
    runner.start(code, &[]);
    runner.until_end()
}

/// `exit()` throws to unwind the script and the script can catch that: the run is over anyway, so
/// the runner has to stop it, report nothing more, and exit by itself.
#[test]
fn a_script_that_keeps_going_after_done_is_stopped() {
    for code in [
        "try { exit() } catch {} for (;;) {}",
        "try { exit() } catch {} while (true) await null",
        "try { exit() } catch {} tools.t(); text('late'); await null; return 1",
    ] {
        let mut runner = Runner::spawn("none");
        runner.start(code, &["t"]);
        let messages = runner.until_end();
        assert_eq!(messages.len(), 1, "{code}: {messages:?}");
        assert_eq!(messages[0]["type"], "done", "{code}");
        assert_eq!(runner.recv(), None, "{code}: nothing after done");
        assert!(runner.child.wait().unwrap().success(), "{code}");
    }
}

#[test]
fn returns_the_value_as_json_text() {
    let messages = run_script("return { a: [1, 'x'] }");
    assert_eq!(
        messages,
        [json!({ "type": "done", "ok": true, "value": "{\"a\":[1,\"x\"]}", "writes": "[]" })]
    );
}

#[test]
fn undefined_value_is_left_out() {
    let messages = run_script("");
    assert_eq!(messages, [json!({ "type": "done", "ok": true, "writes": "[]" })]);
}

#[test]
fn parallel_calls_settle_in_any_order() {
    let mut runner = Runner::spawn("none");
    runner.start(
        "const r = await Promise.all([tools.t(1), tools.t(2), tools.t(3)]); return r",
        &["t"],
    );
    let calls: Vec<Value> = (0..3).map(|_| runner.recv().unwrap()).collect();
    let ids: Vec<i64> = calls.iter().map(|c| c["id"].as_i64().unwrap()).collect();
    assert_eq!(ids, [1, 2, 3]);
    assert_eq!(
        calls[1],
        json!({ "type": "call", "id": 2, "target": "tool", "name": "t", "args": "2" })
    );
    for id in [3, 1, 2] {
        runner.send(&json!({ "type": "result", "id": id, "ok": true, "payload": (id * 10).to_string() }));
    }
    let end = runner.until_end();
    assert_eq!(end[0]["value"], "[10,20,30]");
}

#[test]
fn failed_calls_reject_with_the_message() {
    let mut runner = Runner::spawn("none");
    runner.start("try { await tools.t(); } catch (e) { return e.message }", &["t"]);
    let call = runner.recv().unwrap();
    assert_eq!(call.get("args"), None, "no argument means no args field");
    runner.send(&json!({ "type": "result", "id": 1, "ok": false, "payload": "no such thing" }));
    assert_eq!(runner.until_end()[0]["value"], "\"no such thing\"");
}

#[test]
fn syntax_errors_are_script_errors() {
    let messages = run_script("return (");
    assert_eq!(messages[0]["ok"], false);
    let error: Value = serde_json::from_str(messages[0]["error"].as_str().unwrap()).unwrap();
    assert_eq!(error["name"], "SyntaxError");
}

#[test]
fn a_script_waiting_for_nothing_is_reported() {
    let messages = run_script("await new Promise(() => {})");
    assert_eq!(messages[0]["ok"], false);
    assert!(messages[0]["error"].as_str().unwrap().contains("can never settle"));
}

#[test]
fn store_writes_are_reported_with_the_result() {
    let mut runner = Runner::spawn("none");
    runner.send(&json!({
        "code": "store('n', load('n') + 1); store('gone', undefined); return load('n')",
        "tools": [], "globals": [], "store": { "n": "41", "gone": "true" }
    }));
    let end = runner.until_end();
    assert_eq!(end[0]["value"], "42");
    assert_eq!(end[0]["writes"], "[[\"n\",\"42\"],[\"gone\"]]");
}

#[test]
fn deterministic_mode_is_refused() {
    let mut runner = Runner::spawn("none");
    runner.send(&json!({ "code": "return 1", "tools": [], "globals": [], "store": {}, "deterministic": { "startedAt": 0, "seed": 1 } }));
    let end = runner.until_end();
    assert_eq!(end[0]["type"], "crash");
}

#[test]
fn a_closed_stdin_before_the_end_is_a_crash() {
    let mut runner = Runner::spawn("none");
    runner.start("await tools.t()", &["t"]);
    runner.recv().unwrap();
    drop(runner.stdin.take());
    assert_eq!(runner.until_end()[0]["type"], "crash");
}

#[test]
fn the_heap_limit_comes_from_the_start_data_too() {
    let mut runner = Runner::spawn("none");
    runner.send(&json!({
        "code": "try { const a = []; while (true) a.push(new Array(1e4).fill(1)); } catch (e) { return String(e.message) }",
        "tools": [], "globals": [], "store": {}, "memoryLimitBytes": 8 * 1024 * 1024
    }));
    assert_eq!(runner.until_end()[0]["value"], "\"out of memory\"");
}

#[test]
fn arguments_are_validated() {
    for args in [
        vec![],
        vec!["--sandbox=none"],
        vec!["--memory-limit-mb=8"],
        vec!["--sandbox=bogus", "--memory-limit-mb=8"],
    ] {
        let status = Command::new(BIN)
            .args(&args)
            .stdin(Stdio::null())
            .output()
            .unwrap()
            .status;
        assert_eq!(status.code(), Some(2), "{args:?}");
    }
}

/// The kernel's view of a process that waits for the host: how many seccomp filters it has.
/// Compared with an unsandboxed run, because the test itself may run under a filter.
fn filters_while_waiting(mode: &str) -> (u32, String) {
    let mut runner = Runner::spawn(mode);
    runner.start("await tools.t(); return 1", &["t"]);
    runner.recv().unwrap(); // the call: the script is now blocked waiting for the host
    let status = std::fs::read_to_string(format!("/proc/{}/status", runner.child.id())).unwrap();
    let field = |name: &str| {
        status.lines().find(|l| l.starts_with(name)).unwrap()[name.len()..]
            .trim()
            .to_string()
    };
    let (filters, no_new_privs) = (field("Seccomp_filters:").parse().unwrap(), field("NoNewPrivs:"));
    runner.send(&json!({ "type": "result", "id": 1, "ok": true, "payload": "null" }));
    assert_eq!(runner.until_end()[0]["value"], "1", "{mode}");
    assert!(runner.child.wait().unwrap().success(), "{mode}");
    (filters, no_new_privs)
}

#[test]
fn sandboxed_modes_add_a_filter_and_no_new_privs() {
    let (baseline, _) = filters_while_waiting("none");
    for mode in ["seccomp", "full"] {
        let (filters, no_new_privs) = filters_while_waiting(mode);
        assert_eq!(filters, baseline + 1, "{mode}");
        assert_eq!(no_new_privs, "1", "{mode}");
    }
}

/// Clocks, randomness, local time and hashing must work without the syscalls the filter dropped
/// (`getrandom`, `clock_gettime`): the filter kills the process on anything unlisted.
#[test]
fn time_and_randomness_work_under_the_full_sandbox() {
    let mut runner = Runner::spawn("full");
    runner.start(
        "const m = new Map(); for (let i = 0; i < 1000; i++) m.set('k' + i, i); \
         return [Date.now() > 0, Math.random() < 1, new Date().getFullYear() > 2000, m.size]",
        &[],
    );
    assert_eq!(
        runner.until_end(),
        [json!({ "type": "done", "ok": true, "value": "[true,true,true,1000]", "writes": "[]" })]
    );
}
