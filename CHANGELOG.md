# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

## 0.6.1 — 2026-08-13

### Breaking changes

- `Ai_provider_anthropic.Model_catalog.known_model` dropped `Claude_opus_4_7`,
  `Claude_opus_4_6`, and `Claude_sonnet_4_6`. These model ids still work through
  the `Custom` pass-through, but they no longer resolve to a known constructor,
  so they lose catalog-backed capabilities (`Custom` reports no thinking support,
  no structured output, and no prompt caching). Exhaustive matches over
  `known_model` must drop the removed arms.

### Anthropic provider (`ai_provider_anthropic`)

- **Restored `Claude_haiku_4_5`**, dropped from the catalog in 0.6 by oversight.
  `to_model_id` returns the pinned `claude-haiku-4-5-20251001`, and `of_model_id`
  accepts both `claude-haiku-4-5` and the dated id. Capabilities follow
  `docs/plans/2026-08-03-adaptive-thinking-support.md`: manual budgeted thinking
  only (no adaptive), no effort levels, `Summarized` display default, explicit
  disable allowed, 64k max output tokens, and a 4096-token cache minimum. It
  accepts sampling parameters, unlike the 5-series models.

## 0.6 — 2026-08-12

### Breaking changes

- `Ai_provider.Provider_error.t` gained `retry_after_s`. Custom providers and
  direct record constructors must set it to `None` when no server hint exists.
- `Ai_core.Generate_text_result.step` gained `response_model`. Direct record
  constructors must set it to `None` for steps without a provider response.
- `Ai_provider.Stream_part.Reasoning` gained `provider_options`. Custom
  providers must set it to `Ai_provider.Provider_options.empty` when they
  have no reasoning metadata.
- `Ai_core.Text_stream_part.Reasoning_start` / `Reasoning_delta` /
  `Reasoning_end` and the matching `Ui_message_chunk` constructors gained
  `provider_metadata`. Custom transforms and chunk producers must set it to
  `None` when no metadata is available.
- `Ai_provider_anthropic.Convert_response.content_block_json` gained `data`.
  Direct record constructors must set it to `None` for non-redacted blocks.
- `Ai_provider_anthropic.Convert_prompt.anthropic_content` gained
  `A_redacted_thinking`; exhaustive pattern matches must handle it.
- `Ai_provider_anthropic.Thinking.t` is now `Enabled`, `Adaptive`, or
  `Disabled`; migrate `{ enabled = true; budget_tokens }` to `Enabled {
  budget_tokens; display = None }` and `{ enabled = false; _ }` to `Disabled`.
- `Ai_provider_anthropic.Anthropic_options.t` gained `effort`, and
  `Anthropic_api.output_config` gained `effort` while making `format`
  optional. Use `None` for either field when it is not configured.
- `Ai_provider_anthropic.Beta_headers.required_betas` now accepts
  `thinking:Thinking.t option`; replace the old `true` with `Some (Enabled
  ...)` and `false` with `None`.
- `Ai_provider_anthropic.Model_catalog.model_capabilities` replaced
  `supports_thinking` with detailed `thinking` capabilities and added
  `rejects_sampling_parameters`.

### Core SDK (`ai_core`)

- Retryable provider errors now honor a server `retry_after_s` hint with
  upstream replace semantics: an accepted hint *replaces* the exponential
  backoff for that attempt (it can shorten as well as lengthen the delay,
  rather than acting as a lower bound). Following upstream, a hint is accepted
  only when reasonable — non-negative and either below 60s or below the
  un-jittered exponential delay for the attempt; otherwise it is rejected and
  the jittered exponential backoff is used. Jitter never applies to an accepted
  hint. `generate_text`, `stream_text`, and `Server_handler.handle_chat` accept
  `?max_retry_delay_ms`: an ordinary backoff delay above the cap is clamped down
  to it, while an accepted hint above the cap stops retries without sleeping or
  issuing another request.
- Generation steps expose the provider-reported `response_model`, including
  distinct models selected on successive tool-loop calls and OpenRouter
  streams.

### Provider errors (`ai_provider`)

- Added `Ai_provider.Retry_after.parse`, a shared parser turning `retry-after-ms`
  (milliseconds, more precise, used by e.g. OpenAI) and `retry-after` (fractional
  or integer seconds) headers into `retry_after_s` seconds. `retry-after-ms`
  takes precedence, except a non-numeric or NaN `retry-after-ms` falls through
  to `retry-after` (matching upstream `parseFloat`). Infinite and negative
  values yield no hint. The HTTP-date form of `retry-after` is not supported.

### Provider wiring (`ai_provider_anthropic`, `ai_provider_openai`, `ai_provider_openrouter`)

- Anthropic, OpenAI, and OpenRouter HTTP error responses now populate
  `retry_after_s` from both `retry-after-ms` and `retry-after` response headers
  via the shared parser (fractional seconds and the millisecond header are both
  honored; previously OpenRouter parsed only integer `retry-after` seconds).
  `Anthropic_error.of_response` and `Openai_error.of_response` gained optional
  `?retry_after_ms` / `?retry_after` header arguments and a trailing `unit`;
  `Openrouter_error.of_response_with_retry_after` gained an optional
  `?retry_after_ms`. The custom JSON-only `fetch` callbacks carry no headers and
  therefore no retry hint.
- OpenRouter streaming responses preserve the reported model and serving provider.

## 0.5 — 2026-07-06

### OpenRouter provider (`ai_provider_openrouter`)

- **Error handling hardened.** Completions with `finish_reason = "error"` now
  map to `Finish_reason.Error`, and error-shaped completion bodies (top-level
  or per-choice `error` objects) raise a `Provider_error` instead of being
  reduced to empty output. The error body is a human-readable message
  (upstream provider name, the most specific upstream message from
  `error.metadata.raw`, and the `error_type` suffix) rather than a raw JSON
  dump. Retryability now keys off the real HTTP status on the transport error
  path (an inner provider `error.code` no longer overrides a 5xx gateway
  status), and 200-embedded / streaming errors derive their status from
  `error.code`, tolerating string and float encodings.

## 0.4 — 2026-06-02

### Breaking changes

Source-breaking for downstream code that constructs these records directly
or pattern-matches without `; _`. Code that goes through the documented
constructors (`Core_tool.create`, `Prompt_builder.resolve_messages`,
`Cache_control.ephemeral` / `ephemeral_1h`) is unaffected.

- `Ai_provider.Prompt.System` gained `provider_options : Provider_options.t`
  alongside `content`. Callers building `System { content }` literally must
  add `provider_options = Ai_provider.Provider_options.empty`.
- `Ai_provider.Tool.t` gained `provider_options : Provider_options.t`. The
  in-tree OpenAI / OpenRouter providers were updated; external providers
  constructing this record need the same.
- `Ai_provider.Stream_part.Finish` gained `provider_metadata`. The
  standalone `Provider_metadata` constructor is removed — its data now
  rides on `Finish`.
- `Ai_core.Core_tool.t` gained `provider_options`. The `create` /
  `create_with_approval` / `create_client_tool` helpers take an optional
  `?provider_options` defaulting to empty, so call sites that use them are
  unaffected.
- `Ai_provider_anthropic.Cache_control.t` gained `ttl : ttl option`.
  Construct via `Cache_control.ephemeral` (5m, default) or
  `Cache_control.ephemeral_1h`.
- Removed `Ai_provider_anthropic.Cache_control.breakpoint_to_json` /
  `breakpoint_of_json` from the public mli — they silently dropped the
  `ttl` field and had no in-tree callers.

### Anthropic provider (`ai_provider_anthropic`)

- **Prompt caching reaches the high-level API.** The `cache_control`
  plumbing landed in 0.3 was only usable through `Ai_provider.Language_model`
  directly. `Ai_core.Generate_text.generate_text`,
  `Ai_core.Stream_text.stream_text`, and `Ai_core.Server_handler.handle_chat`
  now accept `?system_provider_options` for the prepended system prompt,
  and `Core_tool.t` gains a `provider_options` field that flows through to
  the provider `Tool` record. The runnable `examples/prompt_caching` demo
  exercises the new path.
- **`Stream_part.Finish` carries `provider_metadata`** matching upstream
  `LanguageModelV4StreamPart`. The standalone `Provider_metadata` chunk is
  removed; Anthropic cache token metrics now ride on the terminal `Finish`
  chunk on cached requests, and `Stream_text_result.provider_metadata` /
  `Generate_text_result.step.provider_metadata` expose them to callers.
  Cache fields are read from `message_start.message.usage` (where Anthropic
  actually emits them) with a fallback to `message_delta.usage`.
- **System messages always serialize as array-of-blocks** on the wire,
  matching upstream `@ai-sdk/anthropic`. The previous "joined string when
  no `cache_control`, array when `cache_control` is set" behavior changed
  the model's input based on a feature flag.
- Anthropic usage decoders now ignore unknown fields, including nested
  `cache_creation` fields, so new provider-side usage metadata does not
  break response parsing.

### OpenRouter provider (`ai_provider_openrouter`)

- **Prompt caching support.** Added typed `Cache_control` /
  `Cache_control_options` modules for explicit per-block cache breakpoints,
  including Anthropic-compatible `ttl` values (`5m` / `1h`) and fallback
  support for prompts that already use the Anthropic cache-control key.
- **OpenRouter prompt conversion now mirrors upstream.** The provider no
  longer reuses the OpenAI prompt converter for chat messages. It now emits
  OpenRouter-specific `cache_control` placement for system, user, assistant,
  and tool messages, while preserving the no-cache shape for non-system
  messages.
- **Cache usage metadata.** OpenRouter `usage.prompt_tokens_details` is mapped
  into provider metadata as `cache_read_tokens` and `cache_write_tokens`.
  Added `examples/openrouter_prompt_caching` to demonstrate both top-level
  automatic caching and explicit breakpoint mode.

## 0.3 — 2026-04-20

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
