//! One sandboxed QuickJS VM per process, speaking length-prefixed CBOR on stdio. See `--help`
//! and `PROTOCOL.md`.

use rquickjs::{Ctx, Runtime};
use tiny_js_sandbox::{
    cli::{self, Cli},
    envelope::{Outgoing, PROTO},
    modules::Modules,
    sandbox,
    vm::{self, Out},
};

/// QuickJS's own stack guard, so deep recursion throws a catchable `RangeError`. pi's tests expect
/// more than 1000 levels of recursion, at about 1.6 KiB each here.
const MAX_STACK_SIZE: usize = 2 * 1024 * 1024;

fn main() {
    // SAFETY: closing stderr touches no Rust-owned memory.
    unsafe { libc::close(libc::STDERR_FILENO) };
    std::process::exit(real_main());
}

fn real_main() -> i32 {
    let cli = match cli::parse(std::env::args()) {
        Ok(cli) => cli,
        Err(e) => e.exit(),
    };
    let out = Out::new(std::io::stdout(), cli.max_frame_bytes);
    match run(&cli, &out) {
        Ok(()) => 0,
        Err(message) => {
            out.send_error(&message);
            1
        }
    }
}

/// Setup, then the frame loop; everything that needs syscalls the filter forbids comes first.
fn run(cli: &Cli, out: &std::rc::Rc<Out>) -> Result<(), String> {
    sandbox::close_inherited_fds()?;
    sandbox::set_resource_limits(cli)?;

    let cannot_create = |e: rquickjs::Error| format!("cannot create the VM: {e}");
    let runtime = Runtime::new().map_err(cannot_create)?;
    runtime.set_memory_limit(usize::try_from(cli.memory_limit_bytes).unwrap_or(usize::MAX));
    runtime.set_max_stack_size(MAX_STACK_SIZE);
    Modules::default().install(&runtime);
    let context = vm::create_context(&runtime, cli.allow_clock).map_err(cannot_create)?;
    context.with(|ctx: Ctx<'_>| {
        let api = vm::install(&ctx, out)?;
        if !cli.allow_random {
            vm::disable_random(&ctx)?;
        }
        if cli.allow_clock {
            sandbox::preload_timezone();
        }
        sandbox::enter(cli.sandbox, cli.allow_clock)?;
        out.send(&Outgoing::Hello { proto: PROTO }).map_err(|e| e.to_string())?;
        vm::serve(&ctx, &api, &mut std::io::stdin().lock(), out, cli.max_frame_bytes)
    })
}
