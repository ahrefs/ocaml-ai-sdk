//! The sandbox applies to the process that enters it, so each case re-runs the test binary
//! as a child with `PROBE` set, which makes the `probe` test enter the sandbox and try
//! something forbidden.

use ai_sdk_quickjs_runner::sandbox::{apply_landlock, apply_seccomp};
use std::{fs::File, net::TcpStream, os::unix::process::ExitStatusExt, process::Command};

/// Exit code of a probe whose forbidden operation failed with a permission error.
const DENIED: i32 = 42;
/// Exit code of a probe whose forbidden operation succeeded.
const ALLOWED: i32 = 43;

#[test]
fn probe() {
    let Ok(what) = std::env::var("PROBE") else { return };
    let code = match what.as_str() {
        "landlock_open" => {
            apply_landlock().expect("landlock");
            File::open("/etc/passwd").map_or(DENIED, |_| ALLOWED)
        }
        "landlock_tcp" => {
            apply_landlock().expect("landlock");
            match TcpStream::connect("127.0.0.1:9") {
                Ok(_) => ALLOWED,
                Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => DENIED,
                Err(_) => 1,
            }
        }
        "seccomp_open" => {
            apply_seccomp().expect("seccomp");
            File::open("/etc/passwd").map_or(DENIED, |_| ALLOWED)
        }
        "seccomp_exec_memory" => {
            apply_seccomp().expect("seccomp");
            // SAFETY: the call is expected to be killed by the filter.
            unsafe {
                libc::mmap(
                    std::ptr::null_mut(),
                    4096,
                    libc::PROT_READ | libc::PROT_EXEC,
                    libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                    -1,
                    0,
                );
            }
            ALLOWED
        }
        "seccomp_plain_memory_and_io" => {
            apply_seccomp().expect("seccomp");
            let buffer = vec![7u8; 8 * 1024 * 1024];
            println!("{}", buffer.len());
            0
        }
        other => panic!("unknown probe {other}"),
    };
    std::process::exit(code);
}

fn run_probe(what: &str) -> std::process::ExitStatus {
    Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "probe", "--nocapture", "--test-threads=1"])
        .env("PROBE", what)
        .output()
        .unwrap()
        .status
}

fn landlock_available() -> bool {
    // SAFETY: landlock_create_ruleset with a null attribute only reports the ABI version.
    unsafe { libc::syscall(libc::SYS_landlock_create_ruleset, 0usize, 0usize, 1u32) > 0 }
}

#[test]
fn landlock_denies_file_access() {
    assert!(landlock_available(), "landlock is not available on this kernel");
    assert_eq!(run_probe("landlock_open").code(), Some(DENIED));
}

#[test]
fn landlock_denies_tcp() {
    assert!(landlock_available(), "landlock is not available on this kernel");
    assert_eq!(run_probe("landlock_tcp").code(), Some(DENIED));
}

#[test]
fn seccomp_kills_on_unlisted_syscalls() {
    assert_eq!(run_probe("seccomp_open").signal(), Some(libc::SIGSYS));
}

#[test]
fn seccomp_kills_on_executable_memory() {
    assert_eq!(run_probe("seccomp_exec_memory").signal(), Some(libc::SIGSYS));
}

#[test]
fn seccomp_allows_memory_and_stdio() {
    assert_eq!(run_probe("seccomp_plain_memory_and_io").code(), Some(0));
}
