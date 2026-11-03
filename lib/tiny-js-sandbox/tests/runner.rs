//! End to end: the real binary, driven with minicbor-encoded frames.

mod common;

use common::{text, Runner};
use std::os::unix::process::ExitStatusExt;
use tiny_js_sandbox::envelope::{Incoming, Outgoing, Payload};

#[test]
fn hello_is_the_first_frame_before_anything_is_read() {
    // No frame is sent: hello must arrive anyway.
    let mut runner = Runner::spawn("full", &[]);
    assert_eq!(runner.recv(), Some(Outgoing::Hello { proto: 1 }));
    assert!(runner.finish().success());
}

#[test]
fn clean_eof_exits_zero_with_no_more_frames() {
    let mut runner = Runner::start("none", &[]);
    runner.close_stdin();
    assert_eq!(runner.recv(), None);
    assert!(runner.wait().success());
}

#[test]
fn eval_values() {
    let mut r = Runner::start("full", &[]);
    assert_eq!(r.eval("'a' + 'b'"), Ok(Some(text("ab"))));
    assert_eq!(r.eval("undefined"), Ok(None));
    assert_eq!(r.eval("null"), Ok(None));
    assert_eq!(
        r.eval("new Uint8Array([1, 2, 255])"),
        Ok(Some(Payload::Bytes(vec![1, 2, 255])))
    );
    assert_eq!(
        r.eval("new Uint8Array([9, 8, 7]).buffer"),
        Ok(Some(Payload::Bytes(vec![9, 8, 7])))
    );
    // other views: the viewed bytes only
    assert_eq!(
        r.eval("new Uint16Array([0x0201, 0x0403])"),
        Ok(Some(Payload::Bytes(vec![1, 2, 3, 4])))
    );
    assert_eq!(
        r.eval("new Uint8Array([1, 2, 3, 4, 5]).subarray(1, 4)"),
        Ok(Some(Payload::Bytes(vec![2, 3, 4])))
    );
    assert_eq!(
        r.eval("new DataView(new Uint8Array([5, 6, 7, 8]).buffer, 1, 2)"),
        Ok(Some(Payload::Bytes(vec![6, 7])))
    );
    assert_eq!(r.eval("''"), Ok(Some(text(""))));
    assert!(r.finish().success());
}

#[test]
fn eval_not_transferable() {
    let mut r = Runner::start("full", &[]);
    for code in [
        "1 + 1",
        "true",
        "({})",
        "[1]",
        "(() => 1)",
        "Promise.resolve('x')",
        "10n",
        "Symbol('s')",
    ] {
        assert_eq!(r.eval(code), Err("result is not transferable".to_string()), "{code}");
    }
    // the VM is still alive
    assert_eq!(r.eval("'ok'"), Ok(Some(text("ok"))));
}

#[test]
fn eval_errors() {
    let mut r = Runner::start("full", &[]);
    let error = r.eval("throw new TypeError('boom')").unwrap_err();
    assert!(error.starts_with("TypeError: boom"), "{error}");
    assert!(error.contains("<eval>"), "stack expected: {error}");
    assert_eq!(r.eval("throw 'plain'"), Err("plain".to_string()));
    assert!(r.eval("syntax error here").unwrap_err().contains("SyntaxError"));
    assert_eq!(r.eval("'still alive'"), Ok(Some(text("still alive"))));
}

#[test]
fn eval_as_names_the_script() {
    let mut r = Runner::start("full", &[]);
    let stack = r.eval_text(
        "try { host.evalAs('\\n(function f() { throw new Error(\"x\") })()', 'named.js') } catch (e) { e.stack }",
    );
    assert!(stack.contains("named.js:2"), "{stack}");
    // A completion value comes back, and the script is global and sloppy.
    assert_eq!(
        r.eval_text("host.evalAs('var viaEvalAs = \"v\"; viaEvalAs', 'a.js')"),
        "v"
    );
    assert_eq!(r.eval_text("viaEvalAs"), "v");
}

#[test]
fn state_persists_across_evals() {
    let mut r = Runner::start("full", &[]);
    assert_eq!(
        r.eval("var a = 20; globalThis.b = 1; function f() { return 'f' + a }; undefined"),
        Ok(None)
    );
    assert_eq!(r.eval("f() + a + b"), Ok(Some(text("f20201"))));
    assert_eq!(r.eval("let c = 'x'; undefined"), Ok(None));
    assert_eq!(r.eval("c"), Ok(Some(text("x"))));
}

#[test]
fn host_post_becomes_message_frames_before_the_result() {
    let mut r = Runner::start("full", &[]);
    let id = r.send_eval("host.post('t'); host.post(new Uint8Array([1, 2])); host.post(new Uint16Array([1])); 'done'");
    let (before, result) = r.until_result(id);
    assert_eq!(
        before,
        vec![
            Outgoing::Message(text("t")),
            Outgoing::Message(Payload::Bytes(vec![1, 2])),
            Outgoing::Message(Payload::Bytes(vec![1, 0])),
        ]
    );
    assert_eq!(result, Ok(Some(text("done"))));
}

#[test]
fn host_post_rejects_other_types() {
    let mut r = Runner::start("full", &[]);
    for code in ["1", "null", "undefined", "({})", "[1]", "true"] {
        let name = r.eval_text(&format!(
            "try {{ host.post({code}); 'no throw' }} catch (e) {{ e.name }}"
        ));
        assert_eq!(name, "TypeError", "{code}");
    }
    // nothing was written
    let id = r.send_eval("host.post('marker'); 1");
    let (before, _) = r.until_result(id);
    assert_eq!(before, vec![Outgoing::Message(text("marker"))]);
}

#[test]
fn promise_jobs_are_drained_before_the_result() {
    let mut r = Runner::start("full", &[]);
    let id = r.send_eval(
        "Promise.resolve().then(() => host.post('a')).then(() => host.post('b')); \
         (async () => { await null; await null; host.post('c') })(); 'r'",
    );
    let (before, result) = r.until_result(id);
    let mut posted: Vec<String> = before
        .into_iter()
        .map(|f| match f {
            Outgoing::Message(Payload::Text(t)) => t,
            other => panic!("{other:?}"),
        })
        .collect();
    assert_eq!(posted[0], "a");
    posted.sort();
    assert_eq!(posted, ["a", "b", "c"]);
    assert_eq!(result, Ok(Some(text("r"))));
}

#[test]
fn messages_reach_onmessage_and_promises_drain_after_them() {
    let mut r = Runner::start("full", &[]);
    assert_eq!(
        r.eval(
            "host.onmessage = (x) => { host.post(typeof x === 'string' ? 'text:' + x : \
             'bytes:' + Array.from(new Uint8Array(x)).join(',') + ':' + (x instanceof ArrayBuffer)); \
             Promise.resolve().then(() => host.post('after')); }; undefined"
        ),
        Ok(None)
    );
    r.send(&Incoming::Message(text("hi")));
    assert_eq!(r.recv(), Some(Outgoing::Message(text("text:hi"))));
    assert_eq!(r.recv(), Some(Outgoing::Message(text("after"))));
    r.send(&Incoming::Message(Payload::Bytes(vec![1, 2, 3])));
    assert_eq!(r.recv(), Some(Outgoing::Message(text("bytes:1,2,3:true"))));
    assert_eq!(r.recv(), Some(Outgoing::Message(text("after"))));
    assert_eq!(r.eval("1 && 'alive'"), Ok(Some(text("alive"))));
}

#[test]
fn message_without_a_handler_is_dropped_with_a_warning() {
    let mut r = Runner::start("full", &[]);
    r.send(&Incoming::Message(text("lost")));
    match r.recv() {
        Some(Outgoing::Log { level, text }) => {
            assert_eq!(level, "warn");
            assert!(text.contains("host.onmessage"), "{text}");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(r.eval("'alive'"), Ok(Some(text("alive"))));
}

#[test]
fn a_throwing_handler_logs_an_error_and_the_vm_survives() {
    let mut r = Runner::start("full", &[]);
    r.eval("host.onmessage = () => { throw new Error('handler failed') }; undefined")
        .unwrap();
    r.send(&Incoming::Message(text("x")));
    match r.recv() {
        Some(Outgoing::Log { level, text }) => {
            assert_eq!(level, "error");
            assert!(text.contains("handler failed"), "{text}");
        }
        other => panic!("{other:?}"),
    }
    r.eval("host.onmessage = async () => { throw new Error('async failed') }; undefined")
        .unwrap();
    r.send(&Incoming::Message(text("x")));
    match r.recv() {
        Some(Outgoing::Log { level, text }) => {
            assert_eq!(level, "error");
            assert!(text.contains("async failed"), "{text}");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(r.eval("'alive'"), Ok(Some(text("alive"))));
}

#[test]
fn console_is_captured_as_log_frames() {
    let mut r = Runner::start("full", &[]);
    let id = r.send_eval(
        "console.log('a', 1, null); console.warn('w'); console.error('e'); console.info('i'); console.debug('d'); 'x'",
    );
    let (before, _) = r.until_result(id);
    let log = |level: &str, t: &str| Outgoing::Log {
        level: level.into(),
        text: t.into(),
    };
    assert_eq!(
        before,
        vec![
            log("log", "a 1 null"),
            log("warn", "w"),
            log("error", "e"),
            log("info", "i"),
            log("debug", "d")
        ]
    );
}

#[test]
fn there_are_no_timers_and_the_intrinsics_are_present() {
    let mut r = Runner::start("full", &[]);
    assert_eq!(
        r.eval_text(
            "[typeof setTimeout, typeof setInterval, typeof JSON.parse, typeof Map, typeof Set, typeof Proxy, \
             typeof WeakRef, typeof RegExp, typeof Promise, typeof Uint8Array, typeof eval, typeof host, \
             typeof console, /a+/.test('caa')].join()"
        ),
        "undefined,undefined,function,function,function,function,function,function,function,function,function,object,object,true"
    );
}

fn flags_report(sandbox: &str, flags: &[&str]) -> (String, String) {
    let mut r = Runner::start(sandbox, flags);
    let date = r.eval_text("typeof Date + ',' + typeof performance + ',' + typeof Performance");
    let random = r.eval_text(
        "(() => { try { const x = Math.random(); return (x >= 0 && x < 1) ? 'works' : 'bad' } \
         catch (e) { return e.message + '|frozen=' + Object.isFrozen(Math) } })()",
    );
    assert!(r.finish().success());
    (date, random)
}

#[test]
fn clock_and_random_flag_combinations_at_the_full_level() {
    let disabled = "Math.random is disabled in this sandbox|frozen=true";
    assert_eq!(
        flags_report("full", &[]),
        ("undefined,undefined,undefined".into(), disabled.into())
    );
    assert_eq!(
        flags_report("full", &["--allow-clock"]),
        ("function,object,undefined".into(), disabled.into())
    );
    assert_eq!(
        flags_report("full", &["--allow-random"]),
        ("undefined,undefined,undefined".into(), "works".into())
    );
    assert_eq!(
        flags_report("full", &["--allow-clock", "--allow-random"]),
        ("function,object,undefined".into(), "works".into())
    );
}

#[test]
fn date_is_a_reference_error_without_the_clock() {
    let mut r = Runner::start("full", &[]);
    assert_eq!(
        r.eval_text("try { new Date(); 'no' } catch (e) { e.name }"),
        "ReferenceError"
    );
}

#[test]
fn date_works_in_the_sandbox_with_the_clock() {
    let mut r = Runner::start("full", &["--allow-clock"]);
    // Local time conversions need the zone, which is preloaded before the sandbox.
    assert_eq!(
        r.eval_text(
            "const d = new Date(2020, 5, 15, 12); String(d.getFullYear()) + ':' + typeof d.getTimezoneOffset()"
        ),
        "2020:number"
    );
    assert_eq!(r.eval_text("String(Date.now() > 1.6e12)"), "true");
    assert_eq!(r.eval_text("String(typeof performance.now())"), "number");
}

#[test]
fn random_is_a_different_sequence_on_each_run_with_the_flag() {
    let sample = |r: &mut Runner| r.eval_text("String(Math.random())");
    let mut a = Runner::start("full", &["--allow-random"]);
    let mut b = Runner::start("full", &["--allow-random"]);
    let (x, y) = (sample(&mut a), sample(&mut b));
    assert_ne!(x, "NaN");
    // Seeded from the clock in microseconds at creation: virtually never equal.
    assert_ne!(x, y);
}

#[test]
fn every_sandbox_level_runs_scripts() {
    for level in ["none", "landlock", "seccomp", "full"] {
        let mut r = Runner::start(level, &[]);
        assert_eq!(r.eval("'x'.repeat(3)"), Ok(Some(text("xxx"))), "{level}");
        assert!(r.finish().success(), "{level}");
    }
}

#[test]
fn a_frame_over_the_cap_is_fatal() {
    let mut r = Runner::start("full", &["--max-frame-bytes=1024"]);
    let mut framed = 1025u32.to_le_bytes().to_vec();
    framed.extend(vec![0u8; 1025]);
    r.send_raw(&framed);
    match r.recv() {
        Some(Outgoing::Error { message }) => assert!(message.contains("exceeds"), "{message}"),
        other => panic!("{other:?}"),
    }
    assert_eq!(r.recv(), None);
    assert_eq!(r.wait().code(), Some(1));
}

#[test]
fn only_the_prefix_of_an_oversize_frame_is_needed() {
    // The length alone triggers the error; the payload is never sent.
    let mut r = Runner::start("full", &["--max-frame-bytes=1024"]);
    r.send_raw(&u32::MAX.to_le_bytes());
    assert!(matches!(r.recv(), Some(Outgoing::Error { .. })));
    assert_eq!(r.wait().code(), Some(1));
}

#[test]
fn a_frame_exactly_at_the_cap_is_accepted() {
    use tiny_js_sandbox::envelope::encode_incoming;
    let mut r = Runner::start("full", &["--max-frame-bytes=1024"]);
    // Pad the script with a comment up to the largest frame that fits.
    let frame_for = |pad: usize| {
        encode_incoming(&Incoming::Eval {
            id: 1,
            code: format!("'ok' //{}", "a".repeat(pad)),
        })
    };
    let mut pad = 0;
    while frame_for(pad + 1).len() <= 1024 {
        pad += 1;
    }
    let frame = frame_for(pad);
    assert!(frame.len() >= 1022 && frame.len() <= 1024, "{}", frame.len());
    r.send_payload(&frame);
    assert_eq!(
        r.recv(),
        Some(Outgoing::EvalResult {
            id: 1,
            result: Ok(Some(text("ok")))
        })
    );
    r.finish();
}

#[test]
fn truncated_frames_are_fatal() {
    for bytes in [vec![3u8, 0], vec![5, 0, 0, 0, 0xa1, 0x61]] {
        let mut r = Runner::start("full", &[]);
        r.send_raw(&bytes);
        r.close_stdin();
        assert!(matches!(r.recv(), Some(Outgoing::Error { .. })));
        assert_eq!(r.wait().code(), Some(1));
    }
}

#[test]
fn malformed_frames_are_fatal_with_an_error_frame() {
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("zero length", vec![]),
        ("indefinite map", vec![0xbf, 0xff]),
        ("not a map", vec![0x01]),
        ("float", vec![0xa1, 0x61, b't', 0xf9, 0, 0]),
        ("unknown type", vec![0xa1, 0x61, b't', 0x61, b'x']),
        (
            "hello from parent",
            tiny_js_sandbox::envelope::encode_outgoing(&Outgoing::Hello { proto: 1 }),
        ),
    ];
    for (name, payload) in cases {
        let mut r = Runner::start("full", &[]);
        match payload.is_empty() {
            true => r.send_raw(&[0, 0, 0, 0]),
            false => r.send_payload(&payload),
        }
        match r.recv() {
            Some(Outgoing::Error { .. }) => {}
            other => panic!("{name}: {other:?}"),
        }
        assert_eq!(r.recv(), None, "{name}");
        assert_eq!(r.wait().code(), Some(1), "{name}");
    }
}

#[test]
fn nothing_is_processed_after_a_violation() {
    let mut r = Runner::start("full", &[]);
    r.send_payload(&[0x01]);
    r.send_eval("host.post('must not run')");
    assert!(matches!(r.recv(), Some(Outgoing::Error { .. })));
    assert_eq!(r.recv(), None);
}

#[test]
fn oversize_posts_throw_a_range_error_and_write_nothing() {
    let mut r = Runner::start("full", &["--max-frame-bytes=1024"]);
    assert_eq!(
        r.eval_text("try { host.post('x'.repeat(2000)); 'no throw' } catch (e) { e.name }"),
        "RangeError"
    );
    assert_eq!(
        r.eval_text("try { host.post(new Uint8Array(2000)); 'no throw' } catch (e) { e.name }"),
        "RangeError"
    );
    let id = r.send_eval("host.post('x'.repeat(900)); 'ok'");
    let (before, result) = r.until_result(id);
    assert_eq!(before, vec![Outgoing::Message(text(&"x".repeat(900)))]);
    assert_eq!(result, Ok(Some(text("ok"))));
}

#[test]
fn an_oversize_result_is_reported_as_an_error() {
    let mut r = Runner::start("full", &["--max-frame-bytes=1024"]);
    let error = r.eval("'x'.repeat(5000)").unwrap_err();
    assert!(error.contains("maximum frame size"), "{error}");
    assert_eq!(r.eval("'alive'"), Ok(Some(text("alive"))));
}

#[test]
fn memory_limit_raises_an_out_of_memory_error_in_the_vm() {
    let mut r = Runner::start("full", &["--memory-limit-mb=16"]);
    let error = r
        .eval("var a = []; for (;;) a.push(new Array(100000).fill(1)); 'unreachable'")
        .unwrap_err();
    assert!(error.contains("out of memory"), "{error}");
    r.eval("a = null; undefined").unwrap();
    assert_eq!(r.eval("'recovered'"), Ok(Some(text("recovered"))));
}

#[test]
fn the_cpu_limit_kills_the_process() {
    let mut r = Runner::start("full", &["--cpu-seconds=1"]);
    r.send_eval("for (;;) {}");
    assert_eq!(r.recv(), None);
    // SIGXCPU at the soft limit, or SIGKILL when the hard limit (equal) is reached first.
    let signal = r.wait().signal();
    assert!(
        signal == Some(libc::SIGXCPU) || signal == Some(libc::SIGKILL),
        "{signal:?}"
    );
}

#[test]
fn killing_the_process_ends_the_stream() {
    let mut r = Runner::start("full", &[]);
    r.child.kill().unwrap();
    assert_eq!(r.recv(), None);
}

/// A field of `/proc/<pid>/status` of the running runner.
fn proc_status(r: &Runner, field: &str) -> String {
    let status = std::fs::read_to_string(format!("/proc/{}/status", r.child.id())).unwrap();
    status
        .lines()
        .find_map(|line| line.strip_prefix(field).and_then(|rest| rest.strip_prefix(':')))
        .unwrap_or_else(|| panic!("no {field} in /proc status"))
        .trim()
        .to_string()
}

#[test]
fn the_binary_applies_the_sandbox_level_it_was_asked_for() {
    // (level, NoNewPrivs, Seccomp): 0 is no filter, 2 is a filter in force.
    for (level, no_new_privs, seccomp) in [
        ("none", "0", "0"),
        ("landlock", "1", "0"),
        ("seccomp", "1", "2"),
        ("full", "1", "2"),
    ] {
        let r = Runner::start(level, &[]);
        assert_eq!(proc_status(&r, "NoNewPrivs"), no_new_privs, "{level}");
        assert_eq!(proc_status(&r, "Seccomp"), seccomp, "{level}");
    }
}

#[test]
fn lone_surrogates_become_replacement_characters() {
    let mut r = Runner::start("full", &[]);
    assert_eq!(r.eval_text("'a\\ud800b'"), "a\u{fffd}b");
    assert_eq!(r.eval_text("'\\udc00'"), "\u{fffd}");
    // A valid pair is kept.
    assert_eq!(r.eval_text("'\\ud83d\\ude00'"), "\u{1f600}");
    let id = r.send_eval("host.post('x\\udbffy'); host.post('\\ud83d\\ude00'); 'done'");
    let (before, result) = r.until_result(id);
    assert_eq!(
        before,
        vec![
            Outgoing::Message(text("x\u{fffd}y")),
            Outgoing::Message(text("\u{1f600}"))
        ]
    );
    assert_eq!(result, Ok(Some(text("done"))));
}

#[test]
fn oversize_payloads_are_refused_without_a_runner_failure() {
    let mut r = Runner::start("full", &["--max-frame-bytes=1024", "--memory-limit-mb=256"]);
    // Tens of MiB over the cap, typed array, buffer and string, as post and as result.
    let error = r.eval("new ArrayBuffer(40 * 1024 * 1024)").unwrap_err();
    assert!(error.contains("maximum frame size"), "{error}");
    let error = r.eval("new Uint8Array(40 * 1024 * 1024)").unwrap_err();
    assert!(error.contains("maximum frame size"), "{error}");
    assert_eq!(
        r.eval_text("try { host.post(new ArrayBuffer(40 * 1024 * 1024)); 'no' } catch (e) { e.name }"),
        "RangeError"
    );
    assert_eq!(
        r.eval_text("try { host.post('y'.repeat(40 * 1024 * 1024)); 'no' } catch (e) { e.name }"),
        "RangeError"
    );
    assert_eq!(r.eval("'alive'"), Ok(Some(text("alive"))));
}

#[test]
fn fatal_errors_leave_stderr_files_untouched() {
    use std::{
        io::Write,
        process::{Command, Stdio},
    };
    let path = std::env::temp_dir().join(format!("tiny-js-stderr-{}", std::process::id()));
    let mut log = std::fs::OpenOptions::new()
        .create_new(true)
        .append(true)
        .open(&path)
        .unwrap();
    let original = b"existing log entry\nexisting log entry\n";
    log.write_all(original).unwrap();
    let mut child = Command::new(common::BIN)
        .args(["--sandbox=none", "--memory-limit-mb=64"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(log)
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let hello = tiny_js_sandbox::frame::read_frame(&mut stdout, 1 << 20)
        .unwrap()
        .unwrap();
    assert!(matches!(
        tiny_js_sandbox::envelope::decode_outgoing(&hello),
        Ok(Outgoing::Hello { .. })
    ));
    let kind = "k".repeat(200 * 1024);
    let mut payload = vec![0xa1, 0x61, b't', 0x7a];
    payload.extend_from_slice(&(kind.len() as u32).to_be_bytes());
    payload.extend_from_slice(kind.as_bytes());
    tiny_js_sandbox::frame::write_frame(&mut stdin, &payload, u32::MAX).unwrap();
    let frame = tiny_js_sandbox::frame::read_frame(&mut stdout, 1 << 20)
        .unwrap()
        .unwrap();
    match tiny_js_sandbox::envelope::decode_outgoing(&frame).unwrap() {
        Outgoing::Error { message } => assert!(message.len() < 200, "{}", message.len()),
        other => panic!("{other:?}"),
    }
    let status = child.wait().unwrap();
    assert_eq!(status.code(), Some(1), "no panic (101), no signal");
    let contents = std::fs::read(&path).unwrap();
    std::fs::remove_file(path).unwrap();
    assert_eq!(contents, original);
}

#[test]
fn control_frames_fit_the_minimum_cap() {
    use std::process::{Command, Stdio};
    use tiny_js_sandbox::{
        envelope::{decode_outgoing, encode_incoming, MAX_UINT, MIN_FRAME_BYTES, TOO_LARGE_RESULT},
        frame::{read_frame, write_frame},
    };
    assert_eq!(
        tiny_js_sandbox::envelope::encode_outgoing(&Outgoing::EvalResult {
            id: MAX_UINT,
            result: Err(TOO_LARGE_RESULT.into()),
        })
        .len(),
        MIN_FRAME_BYTES as usize,
    );
    let mut child = Command::new(common::BIN)
        .args(["--sandbox=full", "--memory-limit-mb=64", "--max-frame-bytes=76"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let recv = |stdout: &mut std::process::ChildStdout| {
        let bytes = read_frame(stdout, MIN_FRAME_BYTES).unwrap().unwrap();
        decode_outgoing(&bytes).unwrap()
    };
    assert_eq!(recv(&mut stdout), Outgoing::Hello { proto: 1 });
    let request = encode_incoming(&Incoming::Eval {
        id: MAX_UINT,
        code: "'x'.repeat(100)".into(),
    });
    write_frame(&mut stdin, &request, MIN_FRAME_BYTES).unwrap();
    assert_eq!(
        recv(&mut stdout),
        Outgoing::EvalResult {
            id: MAX_UINT,
            result: Err(TOO_LARGE_RESULT.into()),
        }
    );
    let mut encoder = minicbor::Encoder::new(Vec::new());
    encoder.map(1).unwrap().str("t").unwrap().str(&"é".repeat(25)).unwrap();
    write_frame(&mut stdin, &encoder.into_writer(), MIN_FRAME_BYTES).unwrap();
    match recv(&mut stdout) {
        Outgoing::Error { message } => {
            assert!(message.starts_with("unknown frame type"));
            assert!(message.ends_with('é'));
        }
        other => panic!("expected fatal error, got {other:?}"),
    }
    assert!(read_frame(&mut stdout, MIN_FRAME_BYTES).unwrap().is_none());
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stderr.is_empty());
}

#[test]
fn unusable_frame_caps_are_rejected_without_stderr() {
    for cap in [1, 75] {
        let output = std::process::Command::new(common::BIN)
            .args(["--memory-limit-mb=64", &format!("--max-frame-bytes={cap}")])
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(output.stderr.is_empty());
    }
}
