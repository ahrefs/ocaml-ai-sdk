# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Anthropic provider (`ai_provider_anthropic`)

- **Native Structured Outputs** — `Object_json` mode now uses Anthropic's
  native `output_config.format = { type: "json_schema", schema }` field on
  capable models (Haiku 4.5, Sonnet 4.5/4.6, Opus 4.5/4.6/4.7), matching
  upstream `@ai-sdk/anthropic`. Schema enforcement is handled by the provider,
  not by appending instructions to the system prompt.
- **Tool-use fallback** — on older models (Sonnet 4.0, Opus 4.0/4.1) and
  unknown `Custom` model ids, the provider synthesises a tool named `json`
  carrying the schema as `input_schema` and forces `tool_choice = { type:
  "tool", name: "json" }`. The caller's system prompt is left untouched.
- **Prompt injection removed** — the previous best-effort "Respond ONLY with
  JSON matching this schema…" system-prompt append has been deleted. Callers
  using `Object_json None` (no schema) now receive an `Unsupported_feature`
  warning because Anthropic cannot enforce JSON without a schema.
- **Model catalog** — added `Claude_opus_4_7`. The
  `supports_structured_output` capability flag is now accurate per model
  (previously defaulted to `true` for all known models).

### Core SDK (`ai_core`)

- **`Output.parse_output`** — when a step has no assistant text, falls back to
  decoding the `json` tool call's `args`. Enables end-to-end structured
  output on the Anthropic fallback path and on any future provider that
  adopts the same convention.
- **`Stream_text`** — `Tool_call_delta` events for the `json` tool drive the
  partial-output parser, so streaming callers see incremental JSON on the
  fallback path with the same UX as the native path.

### Provider abstraction (`ai_provider`)

- **HTTP timeouts.** New `Ai_provider.Http_timeouts` module and
  `Ai_provider.Http_client` wrapper. Defaults: 600s for response headers
  (`request_timeout`) and 300s for silence between streaming chunks
  (`stream_idle_timeout`). Override per-provider via `Config.create
  ?timeouts`. Conservative values chosen to catch stuck connections and
  bugs, not bound legitimate workloads — a 20-minute streaming response
  completes fine as long as chunks keep flowing.
- **New `Provider_error.Timeout` kind** with `phase`
  (`Request_headers` | `Stream_idle`), `elapsed_s`, and `limit_s`.
  `is_retryable` is derived: `Stream_idle` is retryable (connection is
  dead); `Request_headers` is not (server may already be processing the
  request).
- **Fix: `Sse.parse_events` no longer hangs consumers on upstream errors.**
  Previously, an exception from the upstream line stream left the output
  stream pending forever. It now closes cleanly (via `push None`) and
  re-raises to `Lwt.async_exception_hook` so the underlying bug stays
  visible.
- **`Mode.fallback_json_tool_name`** — exported constant (`"json"`) naming the
  synthetic tool used by the structured-output tool-use fallback convention.
  Shared between `ai_core` and providers so the convention has a single
  source of truth.

### Providers (`ai_provider_openai`, `ai_provider_anthropic`, `ai_provider_openrouter`)

- Each `Config.t` gains a `timeouts : Http_timeouts.t` field. All HTTP
  traffic now routes through `Http_client`, removing three copies of the
  unguarded `body_to_line_stream` helper.

### Examples

- `structured_output` — live-API smoke test exercising both the native and
  tool-fallback paths with `ppx_deriving_jsonschema` for schema derivation
  and `melange-json-native`'s `of_json` deriver for typed response decoding.

## 0.2 — 2026-04-14

### Core SDK (`ai_core`)

- **`Smooth_stream`** — stream transformer that buffers `Text_delta` and
  `Reasoning_delta` chunks and re-emits them in controlled pieces with
  configurable inter-chunk delays. Five chunking modes: `Word` (default),
  `Line`, `Regex` (custom Re2 pattern), `Segmenter` (Unicode UAX#29 word
  boundaries via uuseg, recommended for CJK), and `Custom` (user function).
  Matches the upstream AI SDK's `smoothStream` transform.
- **`?transform` parameter** on `stream_text` and `server_handler.handle_chat` —
  generic stream transformer (`Text_stream_part.t Lwt_stream.t ->
  Text_stream_part.t Lwt_stream.t`) applied between the raw event stream and
  consumer-facing streams. Both `full_stream` and `text_stream` reflect the
  transformed output.
- **Retry with exponential backoff** — `Retry` module with jitter, configurable
  initial delay and backoff factor, and parameter validation. `?max_retries`
  threaded through `generate_text`, `stream_text`, and
  `server_handler.handle_chat`. Retries only on errors marked retryable.
- **Telemetry / observability** — `Telemetry` module with OpenTelemetry-compatible
  span instrumentation via the `trace` library (ocaml-trace). Configurable
  `Telemetry.t` settings control enable/disable, input/output recording privacy,
  function ID, custom metadata, and lifecycle integration callbacks (`on_start`,
  `on_step_finish`, `on_tool_call_start`, `on_tool_call_finish`, `on_finish`).
  Span hierarchy matches upstream AI SDK: `ai.generateText` /
  `ai.streamText` root spans, `*.doGenerate` / `*.doStream` step spans, and
  `ai.toolCall` tool execution spans. `?telemetry` parameter threaded through
  `generate_text`, `stream_text`, and `server_handler.handle_chat`.

### Provider Abstraction Layer (`ai_provider`)

- **`is_retryable` field** on `Provider_error.t` — defaults from HTTP status
  code (429, 5xx are retryable). Anthropic and OpenAI providers set it
  explicitly based on error classification.

### Examples

- `smooth_streaming` — demonstrates all five chunking modes
- `telemetry_logging` — demonstrates integration callbacks for lifecycle logging

### Dependencies

- Added `re2` (>= 0.16) and `uuseg` (>= 17.0) to `ai_core`
- Added `trace` (>= 0.12) to `ai_core`

## 0.1 — 2026-04-06

Initial release of the OCaml AI SDK — a type-safe, provider-agnostic AI model
abstraction inspired by the Vercel AI SDK, targeting AI SDK v6 wire compatibility.

### Provider Abstraction Layer (`ai_provider`)

- Extensible GADT-based `Provider_options` for compile-time type-safe
  provider-specific settings
- Role-constrained `Prompt` types (System = string only, User = text + files, etc.)
- `Language_model.S` module type with first-class module wrapper
- `Tool`, `Tool_choice`, `Mode`, `Content` foundation types
- `Finish_reason`, `Usage`, `Warning`, `Provider_error` types
- `Provider.S` and `Middleware.S` module type signatures
- `Call_options`, `Generate_result`, `Stream_part`, `Stream_result` types

### Anthropic Provider (`ai_provider_anthropic`)

- Full Anthropic Messages API implementation with streaming (SSE)
- `Thinking` support with `budget_tokens` smart constructor (>= 1024)
- `Cache_control` for prompt caching
- `Anthropic_options` via the extensible GADT system
- Model catalog with all Claude models (Opus, Sonnet, Haiku families)
- Beta header management and model-aware `max_tokens`
- Prompt conversion with message grouping, tool conversion, response parsing
- Provider factory and public API

### OpenAI Provider (`ai_provider_openai`)

- OpenAI Chat Completions API implementation with streaming (SSE)
- Model catalog with GPT-4o, GPT-4o-mini, o1, o3, o4-mini families
- Tool calling with strict mode support
- Prompt conversion, response parsing, and provider factory

### Core SDK (`ai_core`)

- **`generate_text`** — synchronous text generation with multi-step tool loop
- **`stream_text`** — streaming text generation with multi-step tool loop,
  returns synchronously with streams filled by background Lwt task
- **Output API** — `Output.text`, `Output.object_`, `Output.enum`,
  `Output.array`, `Output.choice` with JSON Schema validation
- **UIMessage stream protocol** — SSE `data: {json}\n\n` encoding with
  `x-vercel-ai-ui-message-stream: v1` header, all v6 chunk types
- **`Ui_message_stream_writer`** — composable stream builder with `write`
  (synchronous) and `merge` (non-blocking via `Lwt.async`), lifecycle
  management, ref-counted in-flight merge tracking, `on_finish` callback
- **Server handler** — cohttp endpoint for chat with CORS support, v6-only
  request parsing with full part type support (text, file, reasoning,
  tool invocations with all states)
- **Tool approval workflow** — `needs_approval` predicate on `Core_tool.t`,
  step loop partitioning, `Tool_approval_request` chunk type, stateless
  re-submission with `approved_tool_call_ids`
- **`Stop_condition`** — step loop termination predicates matching upstream
  `stopWhen`: `step_count_is`, `has_tool_call`, `is_met` (OR semantics
  with short-circuit); wired through `generate_text`, `stream_text`, and
  `server_handler`; `max_steps` remains as independent hard safety cap
- **Partial JSON parser** — for streaming structured output

### Melange Bindings (`ai-sdk-react`)

- `useChat` and `useCompletion` hook bindings for `@ai-sdk/react`
- All v6 message part types including `data_ui_part`
- `classify` function for part type dispatch
- Module-scoped accessors for ergonomic use from OCaml/Reason

### Examples

- `one_shot`, `streaming`, `tool_use`, `thinking`, `generate`, `stream_chat`,
  `agent_loop` — standalone CLI examples
- `chat_server` — cohttp chat server with React frontend, tool approval,
  structured output
- `custom_stream` — custom data streaming with Melange frontend
- `ai-e2e` — end-to-end Melange app with 11 demos (basic chat, reasoning,
  tool use, tool approval, client tools, file attachments, structured output,
  completion, web search, retry/regenerate)

### Infrastructure

- Dune build with `generate_opam_files` for automated opam file generation
- mlx dialect support (OCaml + JSX via `mlx-pp` / `ocamlformat-mlx`)
- Alcotest test suites for all three libraries
- SSE wire format snapshot tests
