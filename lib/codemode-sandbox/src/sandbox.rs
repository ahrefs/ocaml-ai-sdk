//! Restricting the process: resource limits that always apply, and the sandbox that `--sandbox`
//! selects. The runner is single-threaded, which the sandbox relies on: landlock and seccomp
//! filters apply to the calling thread only.

use crate::cli::{Cli, SandboxMode};
use seccompiler::{
    apply_filter, BpfProgram, SeccompAction, SeccompCmpArgLen, SeccompCmpOp, SeccompCondition, SeccompFilter,
    SeccompRule, TargetArch,
};
use std::{collections::BTreeMap, io};

/// Address space allowed beyond the VM's heap: the binary, stacks, allocator overhead.
const ADDRESS_SPACE_HEADROOM: u64 = 256 * 1024 * 1024;

fn os_error(what: &str) -> String {
    format!("{what}: {}", io::Error::last_os_error())
}

/// Closes every descriptor except stdin, stdout and stderr, so nothing inherited from the host
/// survives into the sandbox.
pub fn close_inherited_fds() -> Result<(), String> {
    // SAFETY: close_range takes plain integers.
    match unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) } {
        0 => Ok(()),
        _ => Err(os_error("close_range")),
    }
}

fn set_limit(resource: libc::__rlimit_resource_t, wanted: u64) -> Result<(), String> {
    let mut current = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: `current` is a valid rlimit for the kernel to fill.
    if unsafe { libc::getrlimit(resource, &mut current) } != 0 {
        return Err(os_error("getrlimit"));
    }
    // An existing hard limit that is lower (such as the one of `ulimit -v`) stays in force.
    let value = wanted.min(current.rlim_max);
    let limit = libc::rlimit {
        rlim_cur: value as libc::rlim_t,
        rlim_max: value as libc::rlim_t,
    };
    // SAFETY: `limit` is a valid rlimit.
    match unsafe { libc::setrlimit(resource, &limit) } {
        0 => Ok(()),
        _ => Err(os_error("setrlimit")),
    }
}

/// The limits that apply in every mode: address space as a backstop for the VM's own heap limit,
/// no core dumps, and the CPU time when asked for.
pub fn set_resource_limits(cli: &Cli) -> Result<(), String> {
    set_limit(
        libc::RLIMIT_AS,
        cli.memory_limit_bytes.saturating_add(ADDRESS_SPACE_HEADROOM),
    )?;
    set_limit(libc::RLIMIT_CORE, 0)?;
    match cli.cpu_seconds {
        Some(seconds) => set_limit(libc::RLIMIT_CPU, seconds),
        None => Ok(()),
    }
}

/// Applies the sandbox for `mode`. Any failure is an error; nothing is silently skipped.
pub fn enter(mode: SandboxMode) -> Result<(), String> {
    match mode {
        SandboxMode::None => Ok(()),
        SandboxMode::Seccomp => {
            load_timezone();
            harden_process()?;
            limit_descriptors()?;
            apply_seccomp()
        }
        SandboxMode::Full => {
            load_timezone();
            harden_process()?;
            apply_landlock()?;
            limit_descriptors()?;
            apply_seccomp()
        }
    }
}

/// Reads the time zone now: libc loads `/etc/localtime` on the first local time conversion, which
/// the sandbox forbids, and the process would die on `new Date().getFullYear()`.
fn load_timezone() {
    extern "C" {
        fn tzset();
    }
    // SAFETY: tzset takes no arguments and the runner is single-threaded.
    unsafe { tzset() }
}

/// No privilege gain through exec, no ptrace or core dump of this process, and death with the host.
fn harden_process() -> Result<(), String> {
    // SAFETY: prctl with integer arguments.
    let ok = unsafe {
        libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0
            && libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) == 0
            && libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0) == 0
    };
    if ok {
        Ok(())
    } else {
        Err(os_error("prctl"))
    }
}

/// Only stdin, stdout and stderr may exist, and the landlock ruleset descriptor is already closed.
fn limit_descriptors() -> Result<(), String> {
    set_limit(libc::RLIMIT_NOFILE, 3)
}

/// Landlock: handle every access right the kernel knows, allow none. ABI 1 (filesystem) is a
/// hard requirement; network and scope rights are added when the kernel has them.
pub fn apply_landlock() -> Result<(), String> {
    use landlock::{
        Access, AccessFs, AccessNet, CompatLevel, Compatible, Ruleset, RulesetAttr, RulesetStatus, Scope, ABI,
    };
    let newest = ABI::V7;
    let status = Ruleset::default()
        .set_compatibility(CompatLevel::HardRequirement)
        .handle_access(AccessFs::from_all(ABI::V1))
        .and_then(|r| {
            r.set_compatibility(CompatLevel::BestEffort)
                .handle_access(AccessFs::from_all(newest))
        })
        .and_then(|r| r.handle_access(AccessNet::from_all(newest)))
        .and_then(|r| r.scope(Scope::from_all(newest)))
        .and_then(|r| r.create())
        .and_then(|r| r.restrict_self())
        .map_err(|e| format!("landlock: {e}"))?;
    match status.ruleset {
        RulesetStatus::NotEnforced => Err("landlock: the kernel does not enforce landlock".to_string()),
        RulesetStatus::FullyEnforced | RulesetStatus::PartiallyEnforced => Ok(()),
    }
}

/// Syscalls the runner may make once sandboxed. Anything else kills the process.
const ALLOWED_SYSCALLS: [i64; 13] = [
    libc::SYS_read,
    libc::SYS_write,
    libc::SYS_close,
    libc::SYS_exit,
    libc::SYS_exit_group,
    libc::SYS_brk,
    libc::SYS_munmap,
    libc::SYS_mremap,
    libc::SYS_madvise,
    libc::SYS_futex,
    libc::SYS_rt_sigreturn,
    libc::SYS_sigaltstack,
    libc::SYS_rt_sigprocmask,
];

/// Syscalls allowed only without `PROT_EXEC` in the given argument: the process never needs
/// executable memory.
const NON_EXECUTABLE_ONLY: [(i64, u8); 2] = [(libc::SYS_mmap, 2), (libc::SYS_mprotect, 2)];

fn seccomp_error(e: impl std::fmt::Display) -> String {
    format!("seccomp: {e}")
}

pub fn apply_seccomp() -> Result<(), String> {
    let mut rules: BTreeMap<i64, Vec<SeccompRule>> =
        ALLOWED_SYSCALLS.iter().map(|&syscall| (syscall, vec![])).collect();
    for (syscall, arg) in NON_EXECUTABLE_ONLY {
        let no_exec = SeccompCondition::new(
            arg,
            SeccompCmpArgLen::Dword,
            SeccompCmpOp::MaskedEq(libc::PROT_EXEC as u64),
            0,
        )
        .map_err(seccomp_error)?;
        rules.insert(syscall, vec![SeccompRule::new(vec![no_exec]).map_err(seccomp_error)?]);
    }
    let arch = TargetArch::try_from(std::env::consts::ARCH).map_err(seccomp_error)?;
    let filter =
        SeccompFilter::new(rules, SeccompAction::KillProcess, SeccompAction::Allow, arch).map_err(seccomp_error)?;
    let program: BpfProgram = filter.try_into().map_err(seccomp_error)?;
    apply_filter(&program).map_err(seccomp_error)
}
