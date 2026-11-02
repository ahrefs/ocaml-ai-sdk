use ai_sdk_quickjs_runner::cli::{parse, Cli, SandboxMode};

fn parse_args(args: &[&str]) -> Result<Cli, clap::Error> {
    parse(std::iter::once("runner").chain(args.iter().copied()).map(String::from))
}

#[test]
fn parses_both_flag_forms() {
    let cli = parse_args(&["--sandbox=full", "--memory-limit-mb", "64", "--cpu-seconds=5"]).unwrap();
    assert_eq!(cli.sandbox, SandboxMode::Full);
    assert_eq!(cli.memory_limit_bytes, 64 * 1024 * 1024);
    assert_eq!(cli.cpu_seconds, Some(5));
}

#[test]
fn sandbox_and_memory_are_required() {
    assert!(parse_args(&["--memory-limit-mb=64"]).is_err());
    assert!(parse_args(&["--sandbox=none"]).is_err());
    assert!(parse_args(&["--sandbox=none", "--memory-limit-mb=0"]).is_err());
}

#[test]
fn rejects_unknown_input() {
    assert!(parse_args(&["--sandbox=maybe", "--memory-limit-mb=1"]).is_err());
    assert!(parse_args(&["--sandbox=none", "--memory-limit-mb=1", "--wat=1"]).is_err());
}
