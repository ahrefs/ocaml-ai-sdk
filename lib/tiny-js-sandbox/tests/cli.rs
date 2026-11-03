use tiny_js_sandbox::cli::{parse, Cli, SandboxMode, DEFAULT_MAX_FRAME_BYTES};

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
fn defaults() {
    let cli = parse_args(&["--memory-limit-mb=8"]).unwrap();
    assert_eq!(cli.sandbox, SandboxMode::Full);
    assert_eq!(cli.cpu_seconds, None);
    assert_eq!(cli.max_frame_bytes, DEFAULT_MAX_FRAME_BYTES);
    assert!(!cli.allow_clock && !cli.allow_random);
}

#[test]
fn all_four_sandbox_levels() {
    for (name, mode) in [
        ("none", SandboxMode::None),
        ("landlock", SandboxMode::Landlock),
        ("seccomp", SandboxMode::Seccomp),
        ("full", SandboxMode::Full),
    ] {
        let cli = parse_args(&[&format!("--sandbox={name}"), "--memory-limit-mb=1"]).unwrap();
        assert_eq!(cli.sandbox, mode);
    }
}

#[test]
fn flags_and_frame_cap() {
    let cli = parse_args(&["--memory-limit-mb=8", "--allow-clock", "--max-frame-bytes=1024"]).unwrap();
    assert!(cli.allow_clock && !cli.allow_random);
    assert_eq!(cli.max_frame_bytes, 1024);
    let cli = parse_args(&["--memory-limit-mb=8", "--allow-random"]).unwrap();
    assert!(!cli.allow_clock && cli.allow_random);
}

#[test]
fn frame_cap_range() {
    for cap in [0, 1, 75] {
        assert!(parse_args(&["--memory-limit-mb=8", &format!("--max-frame-bytes={cap}")]).is_err());
    }
    assert!(parse_args(&["--memory-limit-mb=8", "--max-frame-bytes=76"]).is_ok());
    assert!(parse_args(&["--memory-limit-mb=8", "--max-frame-bytes=1073741824"]).is_ok());
    assert!(parse_args(&["--memory-limit-mb=8", "--max-frame-bytes=1073741825"]).is_err());
    assert!(parse_args(&["--memory-limit-mb=8", "--max-frame-bytes=-1"]).is_err());
}

#[test]
fn memory_is_required_and_positive() {
    assert!(parse_args(&["--sandbox=none"]).is_err());
    assert!(parse_args(&["--sandbox=none", "--memory-limit-mb=0"]).is_err());
}

#[test]
fn rejects_unknown_input() {
    assert!(parse_args(&["--sandbox=maybe", "--memory-limit-mb=1"]).is_err());
    assert!(parse_args(&["--sandbox=none", "--memory-limit-mb=1", "--wat=1"]).is_err());
    assert!(parse_args(&["--memory-limit-mb=1", "--version"]).is_err());
}
