//! Command line: everything the runner needs besides the scripts it is sent.

use crate::envelope::MIN_FRAME_BYTES;
use clap::{value_parser, Arg, ArgAction, Command};
use std::str::FromStr;

/// Largest accepted `--max-frame-bytes` (1 GiB).
pub const MAX_FRAME_BYTES_LIMIT: u32 = 1 << 30;
/// `--max-frame-bytes` when not given (16 MiB).
pub const DEFAULT_MAX_FRAME_BYTES: u32 = 16 * 1024 * 1024;

/// Which parts of the process sandbox are applied.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SandboxMode {
    /// Landlock and seccomp.
    Full,
    /// Landlock only (no filesystem, no TCP) and `no_new_privs`.
    Landlock,
    /// The seccomp syscall allowlist only.
    Seccomp,
    /// Nothing beyond the resource limits.
    None,
}

impl FromStr for SandboxMode {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "full" => Ok(Self::Full),
            "landlock" => Ok(Self::Landlock),
            "seccomp" => Ok(Self::Seccomp),
            "none" => Ok(Self::None),
            other => Err(format!(
                "invalid --sandbox value {other:?}, expected none, landlock, seccomp or full"
            )),
        }
    }
}

/// The parsed command line.
#[derive(Debug)]
pub struct Cli {
    pub sandbox: SandboxMode,
    pub memory_limit_bytes: u64,
    pub cpu_seconds: Option<u64>,
    pub max_frame_bytes: u32,
    pub allow_clock: bool,
    pub allow_random: bool,
}

/// Largest `--memory-limit-mb`, so that the limit in bytes still fits in a `u64`.
const MAX_MEMORY_MB: u64 = 1 << 40;

fn command() -> Command {
    Command::new("tiny-js-sandbox")
        .disable_version_flag(true)
        .about(
            "A sandboxed QuickJS VM, one per process. Speaks length-prefixed CBOR frames on stdio \
             (see PROTOCOL.md): eval and message frames in, hello, eval_result, message, log and \
             error frames out.",
        )
        .arg(
            Arg::new("sandbox")
                .long("sandbox")
                .value_name("MODE")
                .default_value("full")
                .value_parser(|s: &str| s.parse::<SandboxMode>())
                .help(
                    "none: no restriction beyond the resource limits. landlock: no filesystem or TCP \
                     access (needs Landlock ABI 4, Linux 6.7; refused otherwise). seccomp: syscall allowlist only. full: landlock \
                     and seccomp; fails hard if either cannot be applied.",
                ),
        )
        .arg(
            Arg::new("memory-limit-mb")
                .long("memory-limit-mb")
                .value_name("N")
                .required(true)
                .value_parser(value_parser!(u64).range(1..=MAX_MEMORY_MB))
                .help("Heap limit of the VM in MiB, also backed by RLIMIT_AS with headroom."),
        )
        .arg(
            Arg::new("cpu-seconds")
                .long("cpu-seconds")
                .value_name("N")
                .value_parser(value_parser!(u64))
                .help("RLIMIT_CPU; the kernel kills the process once it is used up."),
        )
        .arg(
            Arg::new("max-frame-bytes")
                .long("max-frame-bytes")
                .value_name("N")
                .value_parser(value_parser!(u32).range(i64::from(MIN_FRAME_BYTES)..=i64::from(MAX_FRAME_BYTES_LIMIT)))
                .help("Largest frame accepted or written, in bytes (default 16777216, range 76..1073741824)."),
        )
        .arg(
            Arg::new("allow-clock")
                .long("allow-clock")
                .action(ArgAction::SetTrue)
                .help("Provide Date and Performance, and allow the clock syscalls under seccomp."),
        )
        .arg(
            Arg::new("allow-random")
                .long("allow-random")
                .action(ArgAction::SetTrue)
                .help("Leave Math.random working (it throws by default)."),
        )
}

/// Parses `args`, which start with the program name. Flags take `--flag=value` or `--flag value`.
/// `--help` comes back as an `Err` whose `exit` prints it.
pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Cli, clap::Error> {
    let matches = command().try_get_matches_from(args)?;
    Ok(Cli {
        sandbox: *matches.get_one("sandbox").expect("has a default"),
        memory_limit_bytes: matches.get_one::<u64>("memory-limit-mb").expect("required") * 1024 * 1024,
        cpu_seconds: matches.get_one("cpu-seconds").copied(),
        max_frame_bytes: matches
            .get_one("max-frame-bytes")
            .copied()
            .unwrap_or(DEFAULT_MAX_FRAME_BYTES),
        allow_clock: matches.get_flag("allow-clock"),
        allow_random: matches.get_flag("allow-random"),
    })
}
