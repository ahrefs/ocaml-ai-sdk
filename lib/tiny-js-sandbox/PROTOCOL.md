# tiny-js-sandbox wire protocol (version 1)

This document is the authoritative specification of what `tiny-js-sandbox` speaks on stdio and of
the JavaScript surface it exposes. The runner, the OCaml client (`lib/tiny_js`) and the conformance
shim must all agree with it. Words in capitals (MUST, SHOULD, MAY) are used in the RFC 2119 sense.

`tiny-js-sandbox` is a generic, application-agnostic QuickJS (QuickJS-ng via `rquickjs`) runner.
**One process hosts exactly one VM.** There is no multiplexing and there are no VM ids: creating a VM
is spawning the process, destroying it is closing its stdin or killing it. Anything application
specific (for example codemode's tool protocol) is JavaScript that the embedder loads with an
`eval` frame; it is not part of this protocol.

## 1. Transport and framing

stdin carries parent-to-runner frames, stdout carries runner-to-parent frames. The runner closes
stderr at startup and writes no diagnostics there. Nothing else is ever written to stdout.

The runner is single-threaded and its writes block. Output is limited per frame only (a script
looping on `console.log` or `host.post` can produce unbounded output), so the parent **MUST read
stdout concurrently with writing stdin**, and SHOULD bound the output it is prepared to accept
(for example by killing a VM that exceeds a budget). A parent that writes a large frame without
reading can deadlock against a chatty script; `--cpu-seconds` is the runner-side backstop.

Each frame is:

```
+----------------------+--------------------------------+
| length: u32, LE      | payload: exactly `length` bytes|
+----------------------+--------------------------------+
                         = ONE CBOR data item (section 2)
```

- `length` is the payload size in bytes, little-endian, excluding the 4 length bytes.
- The receiver MUST compare `length` with its `max_frame_bytes` **before allocating or reading**
  the payload. A length of 0 or above the cap is a framing violation.
- The cap is `--max-frame-bytes` (default `16777216`, 16 MiB; the CLI rejects values below `76` and above
  `1073741824`, 1 GiB). The same cap applies to frames the runner writes: a `host.post` whose
  encoded frame would exceed it throws a `RangeError` in JavaScript and writes nothing. The parent
  applies its own cap on frames it receives; it SHOULD use the same value it passed to the runner,
  and MUST NOT send frames larger than the runner's cap. The minimum cap fits all control frames,
  including the fallback eval error with the largest valid id. Fatal-error text is truncated at a
  UTF-8 boundary to fit the cap; control frames never bypass it.
- The payload MUST contain exactly one CBOR item and no trailing bytes.
- Clean EOF on stdin at a frame boundary means "no more frames": the runner exits with status 0.
  EOF in the middle of a length prefix or payload is a framing violation.

### Fatal errors

Any framing violation, CBOR violation (section 2), envelope violation (section 3: unknown frame
type, unknown key, missing key, wrong value type, duplicate key) or protocol-order violation is
**fatal and unrecoverable**: there is no resynchronisation. The receiver

1. SHOULD make a best-effort attempt to write one `error` frame (runner side only; the parent just
   kills the runner),
2. then exits with a non-zero status (runner) or kills the peer (parent).

A parent that decodes a violating frame from the runner MUST treat the VM as dead and fail all
pending evals.

## 2. CBOR subset

Payloads are encoded in a strict subset of CBOR (RFC 8949). Decoders MUST reject everything outside
it with a fatal error. The subset is:

| Major type | Accepted                                                   |
|------------|------------------------------------------------------------|
| 0 unsigned | yes, up to 2^53 - 1 (so ids are exact in JavaScript)       |
| 1 negative | **no**                                                     |
| 2 bytes    | yes, definite length                                       |
| 3 text     | yes, definite length, valid UTF-8 (invalid UTF-8 rejected) |
| 4 array    | **no in the frame envelopes** (OCaml `Cbor` supports it, see below) |
| 5 map      | yes, definite length, TEXT keys only                       |
| 6 tag      | **no**                                                     |
| 7 simple   | only `false` (0xf4), `true` (0xf5), `null` (0xf6). No `undefined`, no other simple values, no floats (half/single/double), no break |

- **Definite lengths only.** Indefinite-length strings, arrays and maps (additional info 31) are
  rejected.
- Encoders MUST emit the shortest form for integers and length heads (the `minicbor` encoder does).
  Decoders are not required to enforce shortest form.
- Map keys are text. Duplicate keys are rejected. Encoders SHOULD emit `"t"` first (the examples
  do); decoders MUST accept any key order.
- **No recursion in envelopes.** Every frame envelope in section 3 is a flat map whose values are
  unsigned integers, text, bytes, booleans or null. The Rust decoder reads these with a fixed,
  non-recursive shape; a nested container anywhere in an envelope is a protocol error, so
  unbounded nesting is never accepted. (The OCaml `Cbor` module is a general codec for this
  subset including arrays and nested maps, and carries a decode-time depth limit, default 16, but
  the frames themselves never use containers.)
- Arbitrary application data crosses the boundary only as `data`/`value`/`code` text or bytes
  fields. Embedders that need structure serialise it themselves (typically `JSON.stringify` into a
  text field).

## 3. Frames

Every frame payload is a map with a text key `"t"` naming the frame type. **Exactly** the keys
listed for a type are allowed; extra keys and unknown `"t"` values are protocol errors, not
ignored. Field types: `uint` (CBOR major 0), `text`, `bytes`, `bool`, `null`.

### 3.1 Runner to parent

| `t`           | Other keys                                                                  |
|---------------|-----------------------------------------------------------------------------|
| `hello`       | `proto`: uint, always `1`                                                   |
| `eval_result` | `id`: uint; `ok`: bool; if `ok` is true, `value`: text \| bytes \| null; if false, `error`: text |
| `message`     | `data`: text \| bytes                                                       |
| `log`         | `level`: text; `text`: text                                                 |
| `error`       | `message`: text                                                             |

- `hello` is the first frame, written before the runner reads anything, and only once. The one
  exception is a **startup failure** (resource limits, VM creation or sandbox setup failing): then
  an `error` frame is written instead, and no `hello` follows. A parent MUST therefore accept
  `error` as the first frame and treat it as a failed start.
  The parent MUST check `proto` and abort (kill) on an unknown version.
- `eval_result` answers exactly one `eval` with the same `id`. Results of concurrent evals are
  produced in the order the evals were processed (section 4), which is the order they were sent.
- `message` carries what JavaScript passed to `host.post`. A JS string is sent as text, an
  `ArrayBuffer` or typed array as bytes.
- `log` carries `console.*` output (`level` is one of `log`, `info`, `debug`, `warn`, `error`;
  arguments are stringified and joined with a space into `text`) and runner warnings (`warn`) or
  errors from callbacks (`error`, for example an exception thrown inside `host.onmessage`).
  Log frames are best effort and ordered with respect to other frames.
- `error` is a fatal protocol or runtime error report (for example out of memory). It is followed
  by a non-zero exit. It is never sent after a frame the runner considers final other than as the
  last frame.

### 3.2 Parent to runner

| `t`       | Other keys                                                                 |
|-----------|----------------------------------------------------------------------------|
| `eval`    | `id`: uint; `code`: text                                                   |
| `message` | `data`: text \| bytes                                                      |

- `eval` evaluates `code` as a **global script** (not a module) in the VM, with filename
  `<eval>`. Declarations (`var`, function declarations, assignments to `globalThis`) persist across
  evals; `let`/`const`/`class` at the top level persist in the script scope as per ECMAScript.
  `id` values are chosen by the parent; the runner does not require them to be unique or
  increasing, but a parent that reuses an id with another eval in flight cannot correlate results.
- `message` is delivered to `host.onmessage` (section 5). Text frames arrive as a JS string, bytes
  frames as an `ArrayBuffer`.
- Any other frame type from the parent (including the runner-to-parent types) is a protocol error.

### 3.3 Eval result conversion

The completion value of the script is converted as follows:

| JavaScript value                                   | Result                                      |
|----------------------------------------------------|---------------------------------------------|
| string                                             | `ok: true`, `value`: text (lone surrogates become U+FFFD) |
| `ArrayBuffer`, `Uint8Array` or other typed array / `DataView` | `ok: true`, `value`: bytes (the viewed bytes) |
| `undefined`, `null`                                | `ok: true`, `value`: null                   |
| anything else (number, boolean, bigint, symbol, object, function, Promise ...) | `ok: false`, `error`: `"result is not transferable"` |
| thrown exception                                   | `ok: false`, `error`: the message, followed by the stack (separated by a newline) when the thrown value is an `Error` with a stack; a thrown non-Error is stringified |

Embedders that want structured results call `JSON.stringify` inside the script. Promises are not
awaited: an `eval` whose value is a Promise is "not transferable"; deliver asynchronous results with
`host.post` instead. A result whose encoded `eval_result` frame would exceed the frame cap is
reported as `ok: false` with an error saying so (the VM stays alive).

## 4. Execution model

- Single-threaded and cooperative. The runner reads one frame, handles it completely, then reads
  the next. Frames are therefore processed strictly in order, and an eval or message handler that
  never returns blocks the VM (limit it with `--cpu-seconds`, section 7).
- **After every eval and every delivered message, pending promise jobs are drained** until none are
  left, before the next frame is read and before the `eval_result` is written (an `eval_result` is
  written after the drain, so `host.post` calls made by promise continuations precede it).
- There are **no timers**: `setTimeout` and `setInterval` do not exist, so nothing ever fires later
  by itself. All asynchrony is driven by incoming frames (promise jobs are drained as above).
- If the VM cannot make progress (the runner reads EOF on stdin), the process exits 0 (section 1).
- The VM has a heap limit (`--memory-limit-mb`). Exceeding it raises JavaScript `InternalError: out
  of memory` inside the VM where QuickJS can; if the runtime is wedged the runner sends an `error`
  frame (best effort) and exits non-zero.

## 5. JavaScript surface

Besides the ECMAScript built-ins (see section 6 for what is removed), the VM has one global:

```js
host.post(x)         // x: string | ArrayBuffer | typed array (incl. Uint8Array)
host.onmessage = fn  // writable; fn(x), x: string for text frames, ArrayBuffer for bytes frames
host.evalAs(code, filename) // evaluates `code` as a global sloppy script named `filename`; returns its completion value
```

`host.evalAs` is an `eval` frame from inside the VM with a chosen filename (QuickJS has no
`//# sourceURL`), so embedders can have stack frames carry a meaningful name. It grants nothing
beyond `eval`; the codemode wrapper uses it for the prelude and for user code.

- Strings always travel as text. A JavaScript string may hold lone surrogates, which have no UTF-8
  encoding: they are **replaced by U+FFFD** (REPLACEMENT CHARACTER), both in `host.post` and in eval
  results, so a string is never refused for its content.
- Size is checked before the payload is copied: a string or buffer larger than `--max-frame-bytes`
  (counted in UTF-16 units for strings, as a lower bound) is refused up front, so the cap protects
  memory and not only the wire.
- `host.post(x)` enqueues a `message` frame (string becomes text; `ArrayBuffer`/typed array becomes
  bytes, copying the viewed range). Any other type throws `TypeError`. If the frame would exceed
  `--max-frame-bytes`, it throws `RangeError` and writes nothing. It returns `undefined`.
- `host.onmessage` is initially `undefined`. When a `message` frame arrives and `host.onmessage` is
  a function it is called with the data (`this` is `host`). If it is not a function the message is
  **dropped** and a `log` frame with level `warn` is emitted. If the handler throws, a `log` frame
  with level `error` (message and stack) is emitted and the VM stays alive.
- Embedders that run untrusted code SHOULD capture `host` in a closure and `delete globalThis.host`
  before evaluating that code, so that the code cannot forge frames. (The codemode wrapper does.)
- `console` is provided (`log`, `info`, `debug`, `warn`, `error`) and produces `log` frames.

## 6. Clock and randomness policy

Both facilities are **off by default** and independent flags.

| Flag            | Effect                                                                                         |
|-----------------|------------------------------------------------------------------------------------------------|
| (neither)       | `Date` and `Performance` are not present in the global object (`typeof Date === "undefined"`, using it is a `ReferenceError`). `Math.random` throws `Error("Math.random is disabled in this sandbox")` and `Math` is frozen. |
| `--allow-clock` | `Date` and `Performance` intrinsics are installed; `tzset()` is preloaded before the sandbox is applied; `clock_gettime`, `gettimeofday` and `clock_nanosleep` are added to the seccomp allowlist (`seccomp` and `full` levels). Without the flag those syscalls stay denied. |
| `--allow-random`| `Math.random` is left as QuickJS ships it. QuickJS seeds it from the clock at context creation, which happens **before** the sandbox is applied, so it works even with the clock off. This flag does **not** allow the `getrandom` syscall; there is no cryptographic randomness in the VM. |

The context is built with all intrinsics except `Date` and `Performance` (unless `--allow-clock`);
it still provides `eval`, JSON, `Promise`, typed arrays, `Map`/`Set`, `Proxy`, `RegExp`,
`WeakRef` and the rest of ECMAScript.

### Threat-model note

Removing the clock and randomness is **defense in depth against microarchitectural timing
attacks** (Spectre-style gadgets need a high-resolution timer), not a hard security boundary: a
script can still measure time indirectly (for example by counting loop iterations between two
messages). The parent MUST NOT leak time to the script either: it must not timestamp, pace or
otherwise let message latency depend on secrets, and it SHOULD NOT embed the current time in
anything it sends. The hard boundaries are the process sandbox (section 7), the memory and CPU
limits, and the frame cap.

## 7. Sandbox levels and limits

`--sandbox <none|landlock|seccomp|full>` (default `full`):

| Level      | Meaning                                                                                  |
|------------|------------------------------------------------------------------------------------------|
| `none`     | No sandbox (for debugging/tests only).                                                    |
| `landlock` | Landlock ruleset denying all filesystem access and TCP bind/connect, plus `no_new_privs`. Requires Landlock ABI 4 (Linux 6.7): on an older kernel the runner refuses to start. |
| `seccomp`  | `no_new_privs` and a seccomp filter allowing only the syscalls needed by the runner (memory management, read/write on stdio, futex, exit); executable memory mappings are killed; unlisted syscalls kill the process. Clock syscalls are added by `--allow-clock`. |
| `full`     | `landlock` and `seccomp` together. The TCP part of landlock is best effort here (older kernels), seccomp being the backstop. |

Other options (all CLI flags, no config file, no environment variables):

| Flag                    | Meaning                                                                           |
|-------------------------|-----------------------------------------------------------------------------------|
| `--memory-limit-mb <n>` | QuickJS heap limit. `RLIMIT_AS` is set to heap + 256 MiB.                          |
| `--cpu-seconds <n>`     | Optional `RLIMIT_CPU`; the kernel kills the process on expiry (the parent sees a signal exit and must fail pending evals). |
| `--max-frame-bytes <n>` | Frame cap, default 16777216, valid range 76 .. 1073741824.                          |
| `--allow-clock`         | See section 6.                                                                    |
| `--allow-random`        | See section 6.                                                                    |
| `--help`                | Print help; there is no `--version`.                                              |

Startup order: close stderr and inherited file descriptors above it, set rlimits, create the runtime and
the context (with the intrinsic set of section 6), install the `Math.random` shim unless
`--allow-random`, `tzset()` if `--allow-clock`, **then** enter the sandbox, then write `hello`, then
enter the frame loop. Everything that needs syscalls the filter later forbids therefore happens
before the filter is installed.

## 8. Lifecycle summary

```
parent                                      runner
  | spawn(--sandbox=full ...)                 |
  |                                           | (setup, enter sandbox)
  |<------------------ hello {proto:1} -------|
  |-- eval {id:1, code} ---------------------->|
  |<-------- message / log ... (as JS runs) --|
  |<-------- eval_result {id:1, ok, ...} -----|
  |-- message {data} ------------------------>| host.onmessage(data)
  |<-------- message {data} (host.post) ------|
  | close stdin                               |
  |                                           | exit 0
```

A parent that sees stdout EOF or the process exit before it expected it MUST fail every pending
eval with an error that includes the exit status, and end its message stream.

## 9. Annotated examples

Each example shows the 4 length bytes, then the CBOR payload. All hex was produced by a small
hand encoder and cross-checked against the rules above.

### hello (runner to parent)

```
10 00 00 00                        length = 16
a2                                 map(2)
  61 74                              text(1) "t"
  65 68 65 6c 6c 6f                  text(5) "hello"
  65 70 72 6f 74 6f                  text(5) "proto"
  01                                 uint 1
```

### eval (parent to runner), `1+1`

```
15 00 00 00                        length = 21
a3                                 map(3)
  61 74                              "t"
  64 65 76 61 6c                     text(4) "eval"
  62 69 64                           text(2) "id"
  01                                 uint 1
  64 63 6f 64 65                     text(4) "code"
  63 31 2b 31                        text(3) "1+1"
```

The completion value `2` is a number and therefore not transferable (section 3.3); the result
below is what `String(1+1)` would produce.

### eval_result, text value

```
1f 00 00 00                        length = 31
a4                                 map(4)
  61 74                              "t"
  6b 65 76 61 6c 5f 72 65 73 75 6c 74   text(11) "eval_result"
  62 69 64                           "id"
  01                                 uint 1
  62 6f 6b                           text(2) "ok"
  f5                                 true
  65 76 61 6c 75 65                  text(5) "value"
  61 32                              text(1) "2"
```

### eval_result, bytes value `00 ff`

```
20 00 00 00
a4 61 74 6b 65 76 61 6c 5f 72 65 73 75 6c 74 62 69 64 02 62 6f 6b f5 65 76 61 6c 75 65
42 00 ff                           bytes(2) 00 ff
```

### eval_result, null value (`undefined` or `null`)

```
1e 00 00 00
a4 61 74 6b 65 76 61 6c 5f 72 65 73 75 6c 74 62 69 64 03 62 6f 6b f5 65 76 61 6c 75 65
f6                                 null
```

### eval_result, error

```
22 00 00 00
a4 61 74 6b 65 76 61 6c 5f 72 65 73 75 6c 74 62 69 64 04 62 6f 6b
f4                                 false
65 65 72 72 6f 72                  text(5) "error"
64 62 6f 6f 6d                     text(4) "boom"
```

### message, text `"hi"` and bytes `01 02` (either direction)

```
13 00 00 00
a2 61 74 67 6d 65 73 73 61 67 65   {"t": "message",
64 64 61 74 61                       "data":
62 68 69                             "hi" (text(2))
}

13 00 00 00
a2 61 74 67 6d 65 73 73 61 67 65 64 64 61 74 61
42 01 02                           bytes(2) 01 02
```

### log

```
19 00 00 00
a3 61 74 63 6c 6f 67               {"t":"log",
65 6c 65 76 65 6c 64 77 61 72 6e     "level":"warn",
64 74 65 78 74 61 78                 "text":"x"}
```

### error (runner to parent, then exit non-zero)

```
1b 00 00 00
a2 61 74 65 65 72 72 6f 72         {"t":"error",
67 6d 65 73 73 61 67 65              "message":
69 62 61 64 20 66 72 61 6d 65        "bad frame"}
```

## 10. Versioning

`proto` in `hello` is the protocol version, currently `1`. Any incompatible change (new required
key, new frame type, changed semantics) bumps it; there is no negotiation, a parent that does not
know the version kills the runner.
