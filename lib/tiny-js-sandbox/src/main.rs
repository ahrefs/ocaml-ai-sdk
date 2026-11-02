//! One sandboxed QuickJS VM per process, speaking length-prefixed CBOR on stdio. See `--help`
//! and `PROTOCOL.md`.

use rquickjs::{Ctx, Runtime};
use std::io::Write;
use tiny_js_sandbox::{
    cli::{self, Cli},
    envelope::{Outgoing, PROTO},
    sandbox,
    vm::{self, Out},
};

/// QuickJS's own stack guard, so deep recursion throws a catchable `RangeError`. pi's tests expect
/// more than 1000 levels of recursion, at about 1.6 KiB each here.
const MAX_STACK_SIZE: usize = 2 * 1024 * 1024;

/// Longest `error` frame message.
const MAX_ERROR_BYTES: usize = 4096;

fn main() {
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
            let end = (0..=MAX_ERROR_BYTES.min(message.len()))
                .rev()
                .find(|&i| message.is_char_boundary(i))
                .unwrap_or(0);
            // The frame goes first: stderr may be a full pipe or closed, and must not delay it.
            out.send_uncapped(&Outgoing::Error {
                message: message[..end].to_string(),
            });
            let _ = writeln!(std::io::stderr(), "tiny-js-sandbox: {}", &message[..end]);
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
        out.send_uncapped(&Outgoing::Hello { proto: PROTO });
        vm::serve(&ctx, &api, &mut std::io::stdin().lock(), out, cli.max_frame_bytes)
    })
}
