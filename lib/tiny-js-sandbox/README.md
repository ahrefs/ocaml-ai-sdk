# ai-sdk-quickjs-runner

A small Rust program that runs **one** codemode script in a QuickJS VM and talks to its host in
JSON lines over stdio. It is a sandbox for model-written JavaScript: the script can compute and call
the tools the host declared, and nothing else. It exists for `ocaml-ai-sdk`'s codemode library.

The script environment and the wire protocol are those of
[pi-codemode](https://github.com/earendil-works/pi/tree/main/packages/codemode) (`@earendil-works/pi-codemode`
1.4.0), so a pi host can drive this binary and pi's prompts and tests apply. Only the transport
differs: pi passes the same messages between a worker thread and its host; here each message is one
JSON object on one line.

## Protocol

One process per script run. stdin and stdout carry one JSON object per line.

1. **Host → runner, first line:** the start data (pi's `VmStartData`):
   `{"code": "...", "tools": [{"name", "jsName", "description"}], "globals": [{"name", "spread"}], "store": {"key": "<json text>"}, "memoryLimitBytes": 1234}`.
   `memoryLimitBytes` is optional and can only lower the `--memory-limit-mb` limit.
   `deterministic` is not supported and ends the run with `crash`.
2. **Runner → host:** pi's `WorkerToHostMessage`:
   - `{"type":"call","id":1,"target":"tool"|"global","name":"x","args":"<json text>"}`; `args` is absent when the script passed no argument.
   - `{"type":"output","item":{"type":"text","text":"...","console"?:true}}` or `{"type":"image","data","mimeType"}`.
   - `{"type":"done","ok":true,"value"?:"<json text>","writes":"<json text>"}` or `{"type":"done","ok":false,"error":"<json {name,message,stack}>"}`.
   - `{"type":"crash","message":"..."}` for a failure of the VM itself.
3. **Host → runner, afterwards:** `{"type":"result","id":1,"ok":true,"payload":"<json text>"}`; with `ok: false`, `payload` is the error message. `payload` is absent for `undefined`.

Values that came from the script travel as JSON *text* inside the string fields. The runner exits
after `done` (status 0), or after `crash` (status 1). Calls are asynchronous: `Promise.all` over `n`
tool calls sends `n` `call` lines before the runner waits for the first `result`, and results may
come back in any order.

There is no `ready` message and no cancel message. If the sandbox cannot be applied, the runner
prints a line on stderr, sends nothing on stdout and exits with status 70, so a host that sees EOF
before any message knows to look at stderr. To cancel or time out, kill the process: the host owns the
clock. A script that computes without calling a tool cannot be interrupted any other way; `--cpu-seconds`
is the backstop.

## Command line

```
ai-sdk-quickjs-runner --sandbox=full|seccomp|none --memory-limit-mb=N [--cpu-seconds=N]
```

- `--sandbox=full`: landlock **and** seccomp. Landlock handles every filesystem right (ABI 1 is required,
  or the run fails) and, when the kernel has them, network and scope rights (TCP connect and bind,
  abstract unix sockets, signals to other processes), allowing none. Seccomp then restricts the
  process to a short allowlist of syscalls (stdio, memory management, futex, exit; no
  clock or random syscalls, `Date.now` uses the vDSO and the time zone is loaded before entering) and kills it on anything else, including `mmap` and `mprotect` with `PROT_EXEC`. The
  process also sets `no_new_privs`, `dumpable=0` and `pdeathsig`, and limits its descriptors to
  stdin, stdout and stderr. If any step fails, the runner exits instead of running unsandboxed.
- `--sandbox=seccomp`: the allowlist only, for kernels or containers without landlock. (Container runtimes' default
  seccomp profiles may block the landlock syscalls, in which case `full` fails and this mode is the one to use.)
- `--sandbox=none`: no restriction beyond the resource limits. For development.
- Always: inherited descriptors are closed, core dumps are disabled, and `RLIMIT_AS` is the heap limit
  plus 256 MiB as a backstop for the VM's own limit, which throws a catchable `InternalError: out of memory`.
  `--cpu-seconds` adds `RLIMIT_CPU`.

The runner is single-threaded on purpose: landlock and seccomp apply to the calling thread.

## Building

Needs Rust 1.87 or later (the floor is `rquickjs`'s). Dependencies are pinned by `Cargo.lock`; the sources are
not in git. `make rust-vendor` runs `cargo vendor --locked` into `vendor/` (git-ignored) and writes
`vendor/config.toml`, the source replacement that the build targets pass to cargo, which then builds with
`--frozen`. The build targets run it on their own when `vendor/` is missing or `Cargo.lock` is newer.
The result is deterministic: cargo checks every downloaded crate against the checksums in the lockfile.

```
make rust-vendor                # from the repository root: needs the network, once per Cargo.lock
make build-codemode-binary      # cargo build --release --frozen, offline
make test-codemode-binary
make install-codemode-binary    # PREFIX=... DESTDIR=...
```

To update dependencies, run `cargo update` (the `resolver.incompatible-rust-versions = "fallback"` setting keeps
the lockfile within the MSRV), then `make rust-vendor`. Build and test with
`rustup toolchain install 1.87` and `cargo +1.87 test --frozen --release` before committing.

## Tests

- `cargo test` (all in `tests/`, `src/` has none): `sandbox.rs` has probes that enter the sandbox and check what is
  denied, `runner.rs` runs the binary like a host, `cli.rs` and `protocol.rs` cover the parsers.
- `make conformance-codemode-binary`: runs pi-codemode's own `sandbox.test.ts` against the binary, with a
  `VmLauncher` (`conformance/src/process-sandbox.ts`) that plugs it into pi's host code in place of its
  worker, in the `--sandbox=full` mode (set `RUNNER_SANDBOX=none` or `seccomp` to change it). Needs
  Node and pnpm; `pnpm check-prelude` checks that `src/prelude.js` still matches the pinned package.

## Provenance

- `src/prelude.js` is `PRELUDE_SOURCE` from `@earendil-works/pi-codemode` 1.4.0, evaluated, unmodified
  (generate it with `pnpm gen-prelude` in `conformance/`). It builds the script's environment: `tools`, `ALL_TOOLS`,
  `console`, `text`, `image`, `exit`, `store`, `load`, the freezing of built-ins and the error and output handling.
  The runner only supplies its native `bridge`. MIT, Copyright (c) 2025 Mario Zechner.
- `conformance/test/sandbox.test.ts` is adapted from pi's `packages/codemode/test/sandbox.test.ts` at tag `v1.4.0`
  (4a08025, same licence). The header of the file lists the changes.
- Known differences: the engine is QuickJS-ng (`rquickjs`), pi's is `quickjs-wasi`. A call costs about 1.6 KiB of
  QuickJS stack here, so the stack guard is 2 MiB (pi's tests expect more than 1000 levels of recursion, which
  512 KiB did not give). `Intl` is not available in this runner. All 48 scenarios of pi's `sandbox.test.ts` pass.
