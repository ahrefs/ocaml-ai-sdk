//! Command line: everything the runner needs besides the script itself.

use clap::{value_parser, Arg, Command};
use std::str::FromStr;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SandboxMode {
    Full,
    Seccomp,
    None,
}

impl FromStr for SandboxMode {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "full" => Ok(Self::Full),
            "seccomp" => Ok(Self::Seccomp),
            "none" => Ok(Self::None),
            other => Err(format!(
                "invalid --sandbox value {other:?}, expected full, seccomp or none"
            )),
        }
    }
}

#[derive(Debug)]
pub struct Cli {
    pub sandbox: SandboxMode,
    pub memory_limit_bytes: u64,
    pub cpu_seconds: Option<u64>,
}

/// Largest `--memory-limit-mb`, so that the limit in bytes still fits in a `u64`.
const MAX_MEMORY_MB: u64 = 1 << 40;

fn command() -> Command {
    Command::new("ai-sdk-quickjs-runner")
        .version(env!("CARGO_PKG_VERSION"))
        .about(
            "Runs one codemode script in a QuickJS VM. The first stdin line is the start data (JSON), \
             the following lines are tool results; stdout carries the VM's messages. One JSON object \
             per line.",
        )
        .arg(
            Arg::new("sandbox")
                .long("sandbox")
                .value_name("MODE")
                .required(true)
                .value_parser(|s: &str| s.parse::<SandboxMode>())
                .help(
                    "full: landlock (no filesystem, TCP, abstract sockets or signals out of the process, \
                     ABI 1 or later required, newer rights used when the kernel has them) and seccomp, \
                     then fails hard if either cannot be applied. seccomp: the syscall allowlist only. \
                     none: no restriction beyond the resource limits.",
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
}

/// Parses `args`, which start with the program name. Flags take `--flag=value` or `--flag value`.
/// `--help` and `--version` come back as an `Err` whose `exit` prints them.
pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Cli, clap::Error> {
    let matches = command().try_get_matches_from(args)?;
    Ok(Cli {
        sandbox: *matches.get_one("sandbox").expect("required"),
        memory_limit_bytes: matches.get_one::<u64>("memory-limit-mb").expect("required") * 1024 * 1024,
        cpu_seconds: matches.get_one("cpu-seconds").copied(),
    })
}
