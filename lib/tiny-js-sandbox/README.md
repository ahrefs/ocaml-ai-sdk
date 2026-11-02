# tiny-js-sandbox

A small Rust program that hosts **one** sandboxed QuickJS VM (QuickJS-ng via `rquickjs`, unpatched) and
talks to its parent in length-prefixed CBOR frames over stdio. **One process per VM**: creating a VM is
spawning the process, destroying it is closing stdin or killing it. There is no multiplexing and there are
no VM ids.

The runner is generic and knows nothing about what runs inside. Anything application specific (for example
codemode's tool protocol, `js/codemode-wrapper.js`) is JavaScript the embedder loads with an `eval` frame.
`lib/tiny_js` is the OCaml client.

## Protocol

[`PROTOCOL.md`](PROTOCOL.md) is the specification: framing (`u32` little-endian length, checked against
`--max-frame-bytes` before allocating), the strict CBOR subset (definite lengths only; unsigned integers,
text, bytes, booleans, null; flat maps with text keys; no tags, floats or containers in envelopes), the
frames (`hello`, `eval`, `eval_result`, `message`, `log`, `error`), the JavaScript surface
(`host.post`, `host.onmessage`, `console`) and the execution model (frames in order, promise jobs drained
after each, no timers). Any framing or CBOR violation is fatal: one best-effort `error` frame, then exit 1.

## Command line

```
tiny-js-sandbox --memory-limit-mb=N [--sandbox=none|landlock|seccomp|full] [--cpu-seconds=N]
                [--max-frame-bytes=N] [--allow-clock] [--allow-random]
```

| Flag | Meaning |
|------|---------|
| `--sandbox` | `full` (default): landlock **and** seccomp, failing hard if either cannot be applied. `landlock`: no filesystem or TCP access plus `no_new_privs`; refused on kernels without Landlock ABI 4 (Linux 6.7), since nothing else would restrict TCP. `full` accepts older kernels for the network part (seccomp is behind it). `seccomp`: the syscall allowlist only (for containers whose profile blocks landlock). `none`: resource limits only (development). |
| `--memory-limit-mb` | Required. QuickJS heap limit; `RLIMIT_AS` is heap + 256 MiB as a backstop. Exceeding the heap throws a catchable `InternalError: out of memory` in the VM. |
| `--cpu-seconds` | Optional `RLIMIT_CPU`; the kernel kills the process when it is used up. |
| `--max-frame-bytes` | Frame cap in both directions, default 16777216, range 1..1073741824. |
| `--allow-clock` | Provide `Date` and `Performance`; preload the time zone; add `clock_gettime`, `gettimeofday`, `clock_nanosleep` to the seccomp allowlist. |
| `--allow-random` | Leave `Math.random` as QuickJS ships it. Does **not** allow `getrandom`. |

By default the context has every intrinsic except `Date` and `Performance`, and `Math.random` throws
`Error("Math.random is disabled in this sandbox")` with `Math` frozen. The two flags are independent.

Startup order: close inherited descriptors, set rlimits, create the runtime and context, install `host`
and `console`, the `Math.random` shim unless `--allow-random`, `tzset()` if `--allow-clock`, **then** enter
the sandbox, then write `hello` and read frames. The process is single-threaded on purpose: landlock and
seccomp apply to the calling thread.

## Sandbox levels and threat model

Landlock handles every filesystem right (ABI 1 required) and, when the kernel has them, network and scope
rights, allowing none. Seccomp restricts the process to stdio, memory management, futex and exit (plus
the clock syscalls with `--allow-clock`), kills it on anything else and on `PROT_EXEC` mappings. The
process also sets `no_new_privs`, `dumpable=0` and `pdeathsig`, and limits its descriptors to stdio.

The hard boundaries are the process sandbox, the memory and CPU limits, and the frame cap. Removing the
clock and randomness is defense in depth against timing attacks, not a boundary: a script can still
measure time indirectly, so the parent must not leak time to it either (see PROTOCOL.md section 6).
Embedders running untrusted code should capture `host` in a closure and `delete globalThis.host` first, so the code cannot forge frames.

## Quickstart (OCaml client)

The `ocaml-ai-sdk.tiny_js` library (`lib/tiny_js`) spawns one runner per VM. Build the binary first
(`make build-tiny-js-binary`); `make test-tiny-js` runs the client tests against it.

```ocaml
let run ~binary =
  let open Lwt.Syntax in
  let* vm =
    Tiny_js.Vm.spawn ~binary ~sandbox:Tiny_js.Vm.Full ~memory_limit_mb:64 ~cpu_seconds:10
      ~on_log:(fun ~level text -> Printf.eprintf "[js %s] %s\n" level text)
      ()
  in
  match vm with
  | Error e -> Lwt.return (prerr_endline e)
  | Ok vm ->
      (* eval: a global script; the result is text, bytes or null (None) *)
      let* r = Tiny_js.Vm.eval vm "1 + 1; JSON.stringify({ a: 1 + 1 })" in
      (match r with
       | Ok (Some (Tiny_js.Vm.Text s)) -> print_endline s
       | Ok (Some (Tiny_js.Vm.Bytes _) | None) | Error _ -> ());
      (* messages: what JS passes to host.post *)
      let msgs = Tiny_js.Vm.messages vm in
      let* _ =
        Tiny_js.Vm.eval vm "host.onmessage = (m) => host.post('echo:' + m)"
      in
      (* send: delivered to host.onmessage (text frames arrive as strings) *)
      let* () = Tiny_js.Vm.send vm (Tiny_js.Vm.Text "hi") in
      let* first = Lwt_stream.get msgs in
      (match first with
       | Some (Tiny_js.Vm.Text s) -> print_endline s
       | Some (Tiny_js.Vm.Bytes _) | None -> ());
      let* status = Tiny_js.Vm.close vm in
      ignore (status : Unix.process_status);
      Lwt.return_unit
```

Clock and randomness are off by default: pass `~allow_clock:true` for `Date`, `~allow_random:true` for
`Math.random`. If the process dies (limits, protocol violation, `Vm.kill`) every pending `eval` fails with
an error and the `messages` stream ends.

## Quickstart (codemode wrapper)

`js/codemode-wrapper.js` speaks pi-codemode's frames as JSON text over `host.post`/`host.onmessage`:

1. `Vm.eval vm wrapper_source` (the file's contents; it evaluates to undefined and removes `host` from
   the global object before any user code runs).
2. `Vm.send vm (Text start_json)` with pi's start data `{code, tools, globals, store}`, then
   `Vm.send vm (Text {|{"type":"check"}|})`.
3. Read `call`/`output`/`done`/`crash` messages from `Vm.messages vm`; answer a `call` with
   `{"type":"result","id":...,"ok":...,"payload":...}` followed by another `{"type":"check"}`.
4. On `done` or `crash`, call `Vm.kill vm`: the wrapper ignores later frames but cannot interrupt a script
   that keeps running.

The node shim `conformance/src/process-sandbox.ts` is a complete worked example.

## Layout

- `src/cli.rs` flags; `src/frame.rs` framing; `src/envelope.rs` the frames over `minicbor`'s token reader
  (non-recursive, no serde); `src/sandbox.rs` limits, landlock, seccomp; `src/vm.rs` the context, the
  `host` surface and the frame loop; `src/main.rs` is the startup sequence.
- `js/bootstrap.js` installs `host` and `console` (embedded in the binary).
- `js/prelude.js` is `PRELUDE_SOURCE` from `@earendil-works/pi-codemode` 1.4.0 (tag `v1.4.0`), evaluated,
  unmodified (`pnpm gen-prelude` in `conformance/`). Not used by the runner: the codemode wrapper
  embeds it. MIT, Copyright (c) 2025 Mario Zechner.
- `js/codemode-wrapper.js` is GENERATED (`pnpm gen-wrapper`, checked by `pnpm check-prelude`) from
  `js/codemode-wrapper.in.js` (our glue: pi's start/result/call/output/done frames as JSON over
  `host.post`/`host.onmessage`, `host` captured and deleted before user code) plus `js/prelude.js`. An
  embedder sends it as one `eval` frame, then the start data as a message, then `{"type":"check"}` after
  every start/result message (see the header of the template), and kills the process on `done`.
- `conformance/src/process-sandbox.ts` and `cbor.ts`: the shim (spawn, eval the wrapper, translate pi's
  JSON frames to CBOR `message` frames).
- `conformance/`: pi's `sandbox.test.ts` (adapted from pi's `packages/codemode/test/sandbox.test.ts` at
  tag `v1.4.0`, same licence) run against the binary.

## Building

Needs Rust 1.87 or later. Dependencies are pinned by `Cargo.lock`; the sources are not in git.
`make rust-vendor` runs `cargo vendor --locked` into `vendor/` (git-ignored) and writes `vendor/config.toml`,
the source replacement the build targets pass to cargo, which builds with `--frozen` (offline). The build
targets run it when `vendor/` is missing or `Cargo.lock` is newer. After changing dependencies run `cargo fetch`
(updates `Cargo.lock`, needs the network), then `make rust-vendor`.

```
make rust-vendor                 # from the repository root, once per Cargo.lock
make build-tiny-js-binary        # release build; binary in _build/tiny-js-sandbox/release/,
                                 # symlinked at lib/tiny-js-sandbox/target/release/tiny-js-sandbox
make test-tiny-js-binary
make install-tiny-js-binary      # PREFIX=... DESTDIR=...
make conformance-tiny-js-binary  # needs node and pnpm
```

## Tests

`cargo test` (everything is in `tests/`, `src/` has none; use `ulimit -v` generously for rustc):

- `cli.rs`: flags, defaults, ranges.
- `frame.rs`: framing, cap before allocation, truncation, EOF.
- `envelope.rs`: round trips, the documented hex examples and every rejection (indefinite lengths, tags,
  floats, bad UTF-8, unknown keys and types, deep nesting, trailing bytes, lying lengths).
- `fuzz.rs`: deterministic random and mutated inputs through the decoders with a counting allocator: no
  panic, no allocation beyond the input size.
- `sandbox.rs`: probes that re-run the test binary, enter landlock or seccomp, and check what is denied
  (exit codes DENIED=42, ALLOWED=43), including the clock syscalls denied by default and allowed with the flag.
- `runner.rs`: the real binary driven by a minicbor harness (`tests/common`): handshake, eval conversions,
  `host.post`/`onmessage`, job draining, frame caps, memory and CPU limits, the four clock/random flag
  combinations at the full sandbox level, all sandbox levels.
