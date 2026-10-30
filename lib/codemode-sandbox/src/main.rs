//! Runs one codemode script in a sandboxed QuickJS VM, speaking JSONL on stdio. See `--help`.

use ai_sdk_quickjs_runner::{cli, protocol, sandbox, vm};
use rquickjs::{Context, Runtime};

/// QuickJS's own stack guard, so deep recursion throws a catchable `RangeError`. pi's tests expect
/// more than 1000 levels of recursion, at about 1.6 KiB each here.
const MAX_STACK_SIZE: usize = 2 * 1024 * 1024;

fn main() {
    std::process::exit(real_main());
}

fn real_main() -> i32 {
    let cli = match cli::parse(std::env::args()) {
        Ok(cli) => cli,
        Err(e) => e.exit(),
    };
    match run(&cli) {
        Ok(()) => 0,
        Err(Failure::Setup(message)) => {
            eprintln!("ai-sdk-quickjs-runner: {message}");
            70
        }
        Err(Failure::Vm(message)) => {
            protocol::send_crash(&message);
            1
        }
    }
}

enum Failure {
    /// Before the script could start; nothing is sent on stdout.
    Setup(String),
    /// While running it; reported to the host as `crash`.
    Vm(String),
}

fn set_memory_limit(runtime: &Runtime, bytes: u64) {
    runtime.set_memory_limit(usize::try_from(bytes).unwrap_or(usize::MAX));
}

fn run(cli: &cli::Cli) -> Result<(), Failure> {
    sandbox::close_inherited_fds().map_err(Failure::Setup)?;
    sandbox::set_resource_limits(cli).map_err(Failure::Setup)?;

    let cannot_create = |e: rquickjs::Error| Failure::Setup(format!("cannot create the VM: {e}"));
    let runtime = Runtime::new().map_err(cannot_create)?;
    set_memory_limit(&runtime, cli.memory_limit_bytes);
    runtime.set_max_stack_size(MAX_STACK_SIZE);
    runtime.set_interrupt_handler(Some(Box::new(vm::finished)));
    let context = Context::full(&runtime).map_err(cannot_create)?;

    sandbox::enter(cli.sandbox).map_err(Failure::Setup)?;

    let mut input = std::io::stdin().lock();
    let line = protocol::read_line(&mut input)
        .map_err(|e| Failure::Vm(format!("cannot read the start data: {e}")))?
        .ok_or_else(|| Failure::Vm("no start data".to_string()))?;
    let start = vm::Start::parse(&line).map_err(Failure::Vm)?;
    if let Some(limit) = start.memory_limit_bytes {
        set_memory_limit(&runtime, limit.min(cli.memory_limit_bytes));
    }
    context
        .with(|ctx| vm::run(&ctx, &start, &mut input))
        .map_err(Failure::Vm)
}
