# UIMessage Stream Composition Design

> Design for roadmap item #3: `createUIMessageStream` / `createUIMessageStreamResponse`

## Overview

A composable stream builder with a writer API so server code can write custom
chunks alongside LLM output in a single SSE response. Matches the upstream
TypeScript SDK's `createUIMessageStream` and `createUIMessageStreamResponse`.

## Module: `Ui_message_stream_writer`

New module at `lib/ai_core/ui_message_stream_writer.ml` / `.mli`.

Separate from `Ui_message_stream` (low-level SSE encoding) — this module owns
the composition abstraction.

### Writer type

```ocaml
type t
val write : t -> Ui_message_chunk.t -> unit
val merge : t -> Ui_message_chunk.t Lwt_stream.t -> unit
```

- `write` — synchronous push of a single chunk into the output stream.
- `merge` — non-blocking. Spawns an `Lwt.async` task that consumes the source
  stream and pushes each chunk into the writer. Returns immediately so the
  caller can continue writing or merging additional streams concurrently.

The writer tracks in-flight merge tasks (ref count) so the stream builder
knows when all merged streams have completed.

#### `Lwt.async` safety in `merge`

`merge` uses `Lwt.async` to consume the source stream in the background.
This is safe because:

1. The push target is an unbounded `Lwt_stream` — pushes never block or fail.
2. `Lwt.catch` wraps the consumer, so exceptions in the merged stream are
   caught and surfaced as `Error` chunks rather than hitting
   `Lwt.async_exception_hook`.
3. The in-flight counter ensures the output stream isn't closed until all
   merge tasks complete — no writes to a closed stream.
4. This follows the same pattern used throughout the codebase (see
   `stream_to_sse`, `convert_stream`, `stream_text`).

### `create_ui_message_stream`

```ocaml
val create_ui_message_stream :
  ?message_id:string ->
  ?on_error:(exn -> string) ->
  ?on_finish:(finish_reason:string option -> is_aborted:bool -> unit Lwt.t) ->
  execute:(Ui_message_stream_writer.t -> unit Lwt.t) ->
  unit ->
  Ui_message_chunk.t Lwt_stream.t
```

Lifecycle:

1. Creates output `Lwt_stream.t` + push function.
2. Pushes `Start { message_id; message_metadata = None }`.
3. Creates a writer wrapping the push function.
4. Calls `execute writer` inside `Lwt.async` with `Lwt.catch`.
5. When `execute` returns AND all in-flight merges complete:
   - Normal: pushes `Finish` chunk, calls `on_finish ~finish_reason:None ~is_aborted:false`.
   - Exception: uses `on_error` to format error, pushes `Error` chunk,
     calls `on_finish ~finish_reason:None ~is_aborted:true`.
6. Pushes `None` to close the stream.

`finish_reason` is always `None` because the stream composer is a generic
primitive — it doesn't know the LLM's finish reason. Callers who merged a
`stream_text` result can get `finish_reason` from `stream_text_result.t`.

### `create_ui_message_stream_response`

```ocaml
val create_ui_message_stream_response :
  ?status:Cohttp.Code.status_code ->
  ?headers:(string * string) list ->
  ?cors:bool ->
  Ui_message_chunk.t Lwt_stream.t ->
  (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t
```

Thin convenience:

1. Pipes chunks through `Ui_message_stream.stream_to_sse`.
2. Delegates to `Server_handler.make_sse_response` with extra headers.
3. `?cors` defaults to `true`, adds `Server_handler.cors_headers`.

## Design decisions

### Minimal `on_finish` (no message reconstruction)

The `on_finish` callback receives `finish_reason` and `is_aborted` only — no
accumulated message or message list. Rationale: `create_ui_message_stream` is
a generic stream composition primitive, not tied to LLM output. When
`stream_text` is involved, the caller already has `stream_text_result.t` with
`steps`, `usage`, `finish_reason` promises for persistence/logging.

**Future work:** If users need server-side message reconstruction, add a chunk
accumulator as a separate concern (roadmap item to be added).

### Explicit `?message_id` (no `original_messages`)

Instead of accepting `original_messages` and doing continuation detection, the
caller passes an explicit `?message_id`. This avoids coupling the stream
composer to UIMessage JSON structure internals. Tests demonstrate the
persistence pattern clearly.

### Non-blocking `merge`

Returns `unit` (not `unit Lwt.t`), matching upstream TypeScript semantics.
The caller can merge a `stream_text` result and continue writing custom
chunks while the LLM streams concurrently.

### Synchronous `write`

Returns `unit`, matching upstream. The underlying push into an unbounded
`Lwt_stream` is inherently synchronous.

## Changes to existing modules

- **`Ui_message_chunk`** — No changes.
- **`Server_handler`** — No changes. `make_sse_response` and `cors_headers`
  are already public.
- **`Ai_core`** — Add `module Ui_message_stream_writer = Ui_message_stream_writer`
  to exports.
- **`dune`** — No dependency changes.

## Test plan

Tests in `test/ai_core/test_ui_message_stream_writer.ml`.

**Core behavior:**
- `write` pushes chunks to output stream
- `merge` interleaves chunks from merged stream
- Output starts with `Start`, ends with `Finish`, then stream closes
- `message_id` in `Start` chunk (usage-oriented persistence pattern test)
- Empty `execute` produces `Start` + `Finish`

**Error handling:**
- Exception in `execute` → `Error` chunk + `on_finish ~is_aborted:true`
- Custom `on_error` formats error message
- Exception in merged stream → `Error` chunk, doesn't kill other writes
- Default `on_error` behavior

**`on_finish` callback:**
- Called on normal completion with `~is_aborted:false`
- Called on error with `~is_aborted:true`
- Waits for in-flight merges before firing

**`create_ui_message_stream_response`:**
- Correct status code and headers (SSE + CORS)
- Body contains SSE-encoded chunks ending with `[DONE]`

## Upstream references

- API: https://ai-sdk.dev/docs/reference/ai-sdk-ui/create-ui-message-stream
- API: https://ai-sdk.dev/docs/reference/ai-sdk-ui/create-ui-message-stream-response
- Usage guide: https://ai-sdk.dev/docs/ai-sdk-ui/streaming-data
