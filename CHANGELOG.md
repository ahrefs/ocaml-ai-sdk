# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Breaking changes

- `Model_catalog.known_model` has new constructors in the Anthropic and OpenAI
  providers, listed below. Exhaustive matches over it need the new arms.
- `Ai_provider_anthropic.Thinking.t` has a new `Between_tools` constructor and
  `Ai_provider_openai.Openai_options.reasoning_effort` a new `Max`, so
  exhaustive matches over them need a new arm.
- The `model_capabilities` records gain fields: `rejects_forced_tool_choice`
  in the Anthropic catalog, `between_tools` in its `thinking_capabilities`, and
  `supports_non_reasoning_parameters` in the OpenAI catalog. Code that builds
  these records needs the new fields.

### Anthropic provider (`ai_provider_anthropic`)

- The catalog adds `Claude_fable_5_1`, `Claude_mythos_5_1`, `Claude_opus_5_5`,
  `Claude_sonnet_5_5` and `Claude_haiku_5_5`. All five run adaptive thinking by
  default, accept every effort level, reject sampling parameters, allow 128k
  output tokens, cache from 512 tokens and omit thinking text by default.
  Thinking cannot be disabled on Fable 5.1, Mythos 5.1, Opus 5.5 or Sonnet 5.5;
  Haiku 5.5 accepts disabled thinking up to `high` effort.
- A model that rejects a forced tool choice (Fable 5.1, Mythos 5.1, Opus 5.5
  and Sonnet 5.5) gets `auto` instead, with a warning. With
  `Tool_choice.Specific`, only the named tool is sent. These requests used to
  fail with a 400.
- `Thinking.Between_tools` turns off up-front thinking on Claude Sonnet 5.5,
  which rejects `Thinking.Disabled`. On Sonnet 5.5, `Disabled` is sent as
  `Between_tools`, with a warning. With `Xhigh` or `Max` effort, the effort is
  lowered to `High`, with a warning. Other catalog models reject
  `Between_tools` with `Invalid_argument`.

### OpenAI provider (`ai_provider_openai`)

- The catalog adds the GPT-5 to GPT-6.1 models that upstream's
  `@ai-sdk/openai` lists, from `Gpt_5` to `Gpt_6_1_terra`. It leaves out
  `gpt-5.2-pro` and `gpt-5.4-pro`, which OpenAI serves only through the
  Responses API, and `gpt-5.2-chat-latest` and `gpt-5.3-chat-latest`, which
  OpenAI has deprecated.
- Fix: GPT-5 and later model ids are reasoning models, as upstream detects
  them, dated or not. `capabilities` used to treat them as chat models, so
  requests sent the `system` role, the sampling parameters and a default
  `max_tokens` of 4096, which reasoning models reject. A chat variant without a
  minor version, such as `gpt-5-chat-latest`, stays a chat model.
- GPT-5.1 and later GPT-5 models keep `temperature` and `top_p` when the
  reasoning effort is `Re_none`, as upstream does. They are still dropped, with
  a warning, at any other effort and on GPT-6.
- `Openai_options.reasoning_effort` adds `Max`, which GPT-5.6 and GPT-6 accept.

### Core SDK (`ai_core`)

- `Stop_condition.is_loop_finished` never stops the tool loop, like upstream's
  `isLoopFinished()`. Unlike upstream, it does not lift the step limit. The
  loop still ends at `max_steps`, which defaults to 1.

## 0.7 — 2026-10-23

### Breaking changes

- Both packages need OCaml 5.4 or later, up from 4.14. The code uses
  `Result.Syntax`, which OCaml 5.4 added. The lower bounds of other
  dependencies rise to the oldest versions that install with OCaml 5.4:
  `ppx_deriving` 6.1.1, `lwt_ppx` 5.9.2, `re2` v0.17.0 and, for
  `ai-sdk-react`, `melange` 6.0.1. `base64` rises to 3.1.0, which added
  `Base64.encode_string`.
- The package no longer depends on cohttp or `lwt_ssl`. Projects that use
  them must depend on them directly. cohttp client settings, such as a
  connection cache set with `Cohttp_lwt_unix.Client.set_cache`, no longer
  apply to provider requests. Code that sets them still compiles.
- `Ai_core.Server_handler` works with any web server instead of cohttp.
  `handle_chat` takes the request body as a string, and it, `make_sse_response`,
  `handle_cors_preflight` (now `unit -> response`) and
  `Ui_message_stream_writer.create_ui_message_stream_response` return a
  `Server_handler.response` record. `?status` is an integer code. See Core SDK
  below for the cohttp version of a chat route.
- `handle_chat` answers `400` with `{"error": message}` for a body that
  `parse_chat_request` rejects, such as one whose `messages` is missing or
  empty, or a message with no `parts` array. Such a body used to reach the
  model as an empty or partial prompt. See Core SDK below for every check.
- Building the package now needs a system libcurl and its headers. opam's
  `curl` package pulls in `conf-libcurl`, which checks for them.
- `Ai_provider.Http_client` has a new API built on libcurl. See Provider HTTP
  client below.
- `Provider_error.error_kind` has a new `Unexpected_error` constructor, so
  exhaustive matches on it need a new case.
- `stream_text` reports `Finish_reason.Error` (`"error"` in the UI stream) for
  a step whose provider stream emitted an error. It used to report `Unknown`
  (`"other"`), so code that matched `Unknown` to spot such a step no longer
  sees it.
- `Openrouter_api.provider_error_of_http_response` takes an
  `Http_client.response`.
- Transport failures fail with `Provider_error` `Network_error` instead of
  the exception cohttp raised, such as `Unix.Unix_error`.
- `Http_timeouts.t` has a new `connect_timeout` field, so a record pattern
  that names every field needs it or a `; _`.
- A tool's `execute` takes a second argument, a `Core_tool.execute_options`
  record with `tool_call_id`, `messages` and `abort_signal`. This changes the
  type of `Core_tool.t.execute` and of the `~execute` argument of
  `Core_tool.create` and `create_with_approval`. A tool written as
  `fun args -> ...` becomes `fun args _options -> ...`. The record is
  private: a test that calls `execute` directly builds it with
  `Core_tool.execute_options ~tool_call_id ()`, whose `?messages` defaults
  to `[]` and `?abort_signal` to none.
- `Core_tool.execute_tool` takes `~messages` and `?abort_signal`, and a
  trailing `()`. Once the signal has fired, a tool's failure fails it with
  `Abort_signal.Aborted`, and cancelling its promise fails it with
  `Lwt.Canceled`, instead of returning an error result. A tool's own
  `Aborted` or `Canceled` is still an error result.
- `Lwt.cancel` on the promise from `generate_text` fails the call with
  `Lwt.Canceled` and stops it. A cancel while a tool ran used to become that
  tool's error result and send the next model request. A `with exn ->`
  handler around `generate_text` now sees `Lwt.Canceled` for every cancel,
  not only for one that landed during a model request, and should re-raise
  it. The compiler can't find such handlers. See Core SDK below.
- `Call_options.abort_signal` is now an `Abort_signal.t option`, a private
  `unit Lwt.t`. Wrap a promise you used as a signal with
  `Abort_signal.of_promise`, or make the signal with `Abort_signal.create`
  or `with_timeout`. Read a signal you receive with `Abort_signal.wait`,
  `race` or `guard`.
- `Anthropic_api.messages`, `Openai_api.chat_completions` and
  `Openrouter_api.chat_completions` take `?abort_signal` and a trailing `()`.
- `Config.fetch_fn` in the Anthropic, OpenAI and OpenRouter providers takes
  `~abort_signal:Ai_provider.Abort_signal.t option` before `~url`.
- `Text_stream_part.t` has a new `Abort` constructor, so exhaustive matches on
  it need a new case.
- `Text_stream_part.Error` carries the exception, `error : exn`, instead of
  its text. `Printexc.to_string error` gives the text it carried before. A
  provider error inside a step is `Provider_error.Provider_error err`, so a
  match on that reads `err`'s provider, kind and retryability, and an API
  error's status. The `Error` part that ends a failed call carries the
  exception the call failed with. `on_chunk` gets the same parts, and the
  `Error` part `Smooth_stream` adds when it fails carries its exception. Code
  that builds an `Error` part, such as a `transform`, passes
  an exception. The `error` chunk from `to_ui_message_stream` keeps its text.
- `Stream_text_result.t` has a new `outcome` field, so code that builds the
  record needs it.
- `stream_text`'s `output` and `provider_metadata` fail when the call fails,
  as `usage`, `finish_reason` and `steps` do. They used to resolve to `None`.
- An exception from `stream_text`'s `on_chunk` on the `Finish` part is
  ignored, since `Finish` is always the last part. It used to add an `Error`
  part after `Finish` and fail `usage`, `finish_reason` and `steps`.

### Provider HTTP client (`ai_provider`)

- Provider requests go through libcurl (`curl` and `curl_lwt`). A system
  libcurl is required.
- `Http_client` has a new API. `post` takes a string URL, header pairs and a
  string body, and returns an abstract `response` read with `status`, `header`
  (case-insensitive), `body_string`, `error_body` and `body_lines`. `body_lines`
  replaces `wrap_body_with_idle_timeout`, and `For_testing.response_of_chunks`
  builds a response from in-memory chunks for tests.
- Transport failures fail with `Provider_error` `Network_error`, carrying
  libcurl's message. DNS, connect, send, receive, empty-reply, truncated-body,
  timeout and HTTP/2 failures are marked retryable. A failed TLS handshake is
  not.
- A transfer option that libcurl rejects, such as a URL over its 8 MB string
  limit, fails with a non-retryable `Network_error`.
- Only `http` and `https` URLs are accepted, whatever protocols the system
  libcurl was built with.
- TLS certificates are verified against the system libcurl's default CA file
  and directory. `SSL_CERT_FILE` replaces the default file and `SSL_CERT_DIR`
  the default directory. A file that cannot be read is skipped, and so is
  `SSL_CERT_DIR` on a TLS backend without CA directory support.
- libcurl built with OpenSSL writes TLS session keys to the file named by
  `SSLKEYLOGFILE` when that variable is set, as browsers do. 0.6.3 ignored it.
  Anyone holding that file and a packet capture can read the API keys sent to
  providers, so leave it unset outside local debugging.
- New `Http_timeouts.connect_timeout`, default 10 seconds, bounds DNS, TCP
  connect and TLS handshake. A connection that stalls no longer
  holds the request until `request_timeout`. It fails with a retryable
  `Network_error`, and only while it is below `request_timeout`. Otherwise
  `request_timeout` fires first with its non-retryable `Request_headers`
  timeout.
- Requests send `User-Agent: ocaml-ai-sdk/<version>` unless the caller passes
  its own `User-Agent` header, and enable TCP keepalive. libcurl also sends
  `Accept: */*`, and over HTTPS uses HTTP/2 when the provider offers it and the
  system libcurl supports it. A header with an empty value goes out as
  `Name;`, libcurl's form for an empty header.
- An error response (status 400 or above) fails with the provider's API
  error, keeping the status and the `retry-after` headers, even when its body
  stalls or breaks off. The error body is read for at most 10 seconds and
  64 KiB. A stalled error body used to hang the call.
- Requests still never go through a proxy. The client turns off libcurl's use
  of the `http_proxy`, `https_proxy` and `all_proxy` environment variables.
- `stream_idle_timeout` now also bounds non-streaming response bodies, which
  previously could hang on a stalled connection.
- A stream that fails partway through (idle timeout, dropped or truncated
  connection) now ends with a `Stream_part.Error` carrying the
  `Provider_error`. It used to close silently and re-raise to
  `Lwt.async_exception_hook`, whose default handler exits the process.
  OpenRouter's `stream` reports a failure before the first completion chunk
  the same way. `body_lines` and `Sse.parse_events` read on demand, and a
  failed read fails with the error. The idle timer runs only while a read is
  waiting, so a stream that nobody reads is not timed out.
  `wrap_body_with_idle_timeout` timed out a stalled connection whether or not
  anyone read the stream.
- New `Stream_pump.pump` runs a provider's per-event converter in the
  background and always closes the output. An event whose JSON fails to decode
  (any Yojson or melange-json decode exception) becomes a
  `Deserialization_error` part with the event's data, and the stream
  continues. Any other exception, from the event stream or the converter,
  becomes an `Error` part and ends the stream: a `Provider_error` as it is,
  anything else as the new `Unexpected_error` kind. Its optional
  `?abort_signal` is the call's signal: once that has fired,
  `Abort_signal.Aborted` and `Lwt.Canceled` end the stream without an
  `Error` part. Before then, or with no signal, they are errors like any
  other, so a stray cancel does not look like a normal end. The Anthropic,
  OpenAI and OpenRouter converters use it, and their `Convert_stream.transform`
  takes the call's signal as `?abort_signal`.
- `Language_model.generate` and `stream` return a failed promise when the
  model's function raises before returning one, instead of raising.
- New `Abort_signal` module for cancelling provider requests, retries and
  streams. `Abort_signal.t` is a private `unit Lwt.t` that settles on abort.
  Operations it interrupts fail with `Abort_signal.Aborted { reason }`. See
  the new guide, `docs/guides/cancellation.md`.
  - `create ()` returns a signal and its abort function,
    `?reason:exn -> unit -> unit`, like `AbortController`. Everything waiting
    on the signal reacts before the function returns, and a second call does
    nothing.
  - `of_promise promise` makes a signal that aborts when `promise` settles.
  - `reason` is the exception the signal failed with, if any.
  - `with_timeout after_s f` runs `f` with a signal that fails with the new
    `Timeout { after_s }` exception, and stops the timer once `f` settles. It
    raises `Invalid_argument` for `nan`.
  - `choose signals f` runs `f` with a signal that aborts when the first of
    `signals` does, with its reason. It never cancels `signals`, and removes
    its callbacks from them once `f` settles.
  - `race signal f` runs `f ()` and fails with `Aborted` as soon as the
    signal fires, cancelling `f`'s promise and never the signal. Cancelling
    `race` cancels `f` too. `generate_text` and `stream_text` already race
    every tool, so use it where the SDK doesn't race, such as a direct
    `execute_tool` call or a tool's own sub-steps. Work that ignores
    `Lwt.cancel` must still watch the signal itself.
  - `with_on_abort signal hook f` runs `hook` if the signal settles while `f`
    runs. `guard`, `wait` and `fail_if_aborted` help code that takes a signal.
- `Http_client.post` takes `?abort_signal`. A signal that has already settled
  fails the call before it connects. An abort before the headers arrive fails
  `post` at once. An abort during the body fails the waiting or next read,
  `error_body` included. In both cases libcurl drops the transfer and closes
  its connection. Cancelling the promise from `post` or from a body read
  drops the transfer too.

### Provider wiring (`ai_provider_anthropic`, `ai_provider_openai`, `ai_provider_openrouter`)

- The models pass `Call_options.abort_signal` to the HTTP client, through the
  API functions' new `?abort_signal`. They used to ignore it.
- A custom `fetch` gets the call's signal as `~abort_signal` and should stop
  once it settles. A call whose signal settles before `fetch` fails with
  `Aborted` without calling it. One whose signal settles during `fetch` fails
  with `Aborted` at once and cancels `fetch`'s promise, even when `fetch`
  ignores the signal.
- OpenRouter's `Convert_stream.peek_response_info` reads the response info
  as `stream` does. When the read fails, the stream it returns delivers that
  failure after the events read so far.
- Fix: streams from OpenAI and OpenRouter report their usage. Both send it in
  a chunk after the finish reason, and the stream used to end its step on the
  finish reason with zero usage. On OpenRouter, that late chunk also left an
  unclosed empty text part in the UI stream. `Stream_pump.pump` has a new
  `?on_end` hook that the providers use to push `Finish` when the stream ends.
- Fix: OpenRouter's reasoning streams as one reasoning part. OpenRouter sends
  an empty `content` with each reasoning delta, and the provider turned each
  one into a text part, which split the reasoning into one-delta parts.

### Core SDK (`ai_core`)

- `Server_handler` no longer depends on cohttp and works with any web server.
  Its responses are a new `Server_handler.response` record (`status`,
  `headers` and a `body : string Lwt_stream.t` to send chunk by chunk), which
  the app sends with its own server:
  - `handle_chat` takes the request body as a string instead of cohttp's
    connection, request and body, and returns a `response` instead of
    `(Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t`.
  - `handle_cors_preflight` takes `()` and returns a `response`.
  - `make_sse_response` and
    `Ui_message_stream_writer.create_ui_message_stream_response` return a
    `response`, and their `?status` is an integer code.

  With cohttp, a callback that called `handle_chat ~model conn req body`
  becomes:

  ```ocaml
  let respond (r : Ai_core.Server_handler.response) =
    Cohttp_lwt_unix.Server.respond ~status:(Cohttp.Code.status_of_code r.status)
      ~headers:(Cohttp.Header.of_list r.headers) ~body:(Cohttp_lwt.Body.of_stream r.body) ()

  let callback _conn _req body =
    let%lwt body = Cohttp_lwt.Body.to_string body in
    respond (Ai_core.Server_handler.handle_chat ~model body)
  ```
- New `Server_handler.parse_chat_request : string -> (chat_request, string)
  result` parses and checks a `useChat()` request body, as an upstream route
  does with `validateUIMessages` and `convertToModelMessages`. A
  `chat_request` holds the prompt messages, the pending tool approvals and the
  parsed body, for fields such as `id`, `trigger` or custom `body` fields. Use
  it to inspect or change a request before calling `stream_text`.
- `handle_chat` now answers `400` with `{"error": message}` for every body
  that `parse_chat_request` rejects: `messages` missing, empty or not an
  array, a message whose role is not `system`, `user` or `assistant`, a
  message with no `parts` array, or a system or user message with no parts,
  as upstream's `validateUIMessages` checks. Such a body used to reach the
  model as an empty or partial prompt. Message `id`s are not required, and
  unknown part types are still skipped. `parse_messages_from_body` and
  `collect_pending_tool_approvals` do not run these checks.
- `parse_messages_from_body`, and so `handle_chat`, no longer drop the whole
  conversation when a message has a data part (`data-*`) whose `data` is not
  a string, such as an object written with `Ui_message_stream_writer`. Such
  a body used to parse as no messages at all.
- `handle_chat`'s `400` response now has `content-type: application/json`,
  and its error message is escaped, so the body is always valid JSON.
- `stream_text` reports finish reason `error` for a step whose provider stream
  emitted an error, matching upstream `streamText`. It used to report `other`.
  The UI stream's `finish` chunk carries it as `finishReason: "error"`.
- `Retry.with_retries` takes `?abort_signal`. No attempt starts once the signal
  has settled, and an abort cuts a backoff or `retry-after` sleep short. An
  attempt that fails with `Aborted` or `Lwt.Canceled` is re-raised as is,
  never retried or wrapped in `Retry_error`.
- `Generate_text.generate_text` takes `?abort_signal` and `?on_abort`. The
  signal goes to every provider request, to the retry loop and to the tools.
  Once it has fired, no model call or tool starts, approved pending tools
  included. The call fails with `Abort_signal.Aborted` when the abort stops
  work it still had to do, and fails at once even when the model or a tool
  ignores the signal. An abort after the final model response, or once
  `stop_when` is met, stops nothing, and the call returns its result, as
  upstream's generateText does. `on_abort` gets the steps recorded so far
  before the call fails, unless the call was cancelled. Once the signal has
  fired, and unless the call was cancelled, any failure of the call, such as
  a model's own `Lwt.Canceled`, becomes `Aborted` and calls `on_abort`.
- The `Telemetry.notify_on_*` functions take an optional `?stop` predicate,
  checked before each integration. `generate_text` and `stream_text` pass
  one, so after a cancel, or an abort during a tool's callbacks, no later
  integration hears of the event, even when a callback ignored the cancel.
  A callback's own `Lwt.Canceled` is printed and skipped like any other
  error, as before.
- `Lwt.cancel` on the promise from `generate_text`, for example through
  `Lwt_unix.with_timeout`, now stops the call: it fails with `Lwt.Canceled`,
  cancels the provider request, retry sleep or tool in progress, and starts no
  further model request or tool. It used to turn the cancel into a tool error
  result and send the next model request. A cancel reports no steps.
- `Stream_text.stream_text` takes `?abort_signal` and `?on_abort`, following
  upstream's streamText. When the signal fires, `on_abort` gets the steps
  recorded so far, then `full_stream` gets a `Text_stream_part.Abort` part
  with the signal's reason and closes. As upstream's onChunk, `on_chunk` does
  not get it. No `Finish_step`, `Finish` or `Error` part follows, and
  `on_step_finish` and `on_finish` are not called again. `usage`,
  `finish_reason`, `steps`, `output` and `provider_metadata` fail with
  `Aborted`, after `on_abort` has run. The job processes no further provider
  part and starts no model call, tool or step after the abort, even when a
  custom model ignores the signal. A signal that has already fired gives a
  stream holding `Start` then `Abort`, without calling the model, and runs
  `on_abort` before `stream_text` returns.
- New `Stream_text_result.outcome`, a promise that never fails and resolves
  to `Finished result`, `Aborted { steps; reason }` or `Failed exn` once the
  call ends.
- `Finish` is now always the last part of `full_stream`. A failed call ends
  with an `Error` part, but a provider error inside a step gives an `Error`
  part too and the step goes on, so use `outcome` to learn how a call ended.
- Tools get a `Core_tool.execute_options` with the call's `abort_signal`, the
  `tool_call_id` and the step's `messages` without the system prompt, as
  upstream's tools get `ToolExecutionOptions`. `execute_tool` fails with
  `Aborted`, without running the tool, once the signal has fired.
- In both `generate_text` and `stream_text`, a tool's result counts only if
  its `execute` returned before the signal fired, even when the abort comes
  while the result is being reported. No tool starts after the abort,
  and a running tool's promise is cancelled. A step whose model response
  came back is always recorded, even when the abort lands during its tool
  batch or before the provider closes its stream. It keeps those results,
  and reaches `on_abort` and `outcome`.
- New `Generate_text_result.total_usage` adds up the usage of a list of
  steps.
- `Generate_text_result.add_usage`, which `generate_text` and `stream_text`
  use for their `usage`, no longer depends on the order of the steps. A record with no
  `total_tokens` counts as its input plus output tokens. Before, it reset
  the running total to the input plus output so far, which dropped any
  reported totals that differed from that sum.
- `on_chunk` now also gets the `Error` part that ends a failed
  `stream_text` call. An exception it raises on that part is ignored.
- `Stream_text.stream_text` now pushes each step's `Finish_step` part before
  calling `on_step_finish`, as upstream does. It used to call
  `on_step_finish` first. An exception from `on_finish` is ignored, since the
  streams and promises have already settled by then. It used to escape to
  `Lwt.async_exception_hook`, whose default handler exits the process.
- `Stream_text_result.to_ui_message_stream` turns the `Abort` part into an
  `abort` chunk carrying the reason, with no `finish` chunk after it.
- `Ui_message_stream_writer.create_ui_message_stream` passes
  `~is_aborted:true` to `on_finish` when an `Abort` chunk was written or merged,
  as well as when `execute` raises. After an `Abort` chunk, it no longer
  pushes its own `finish` chunk. When `execute` raises `Aborted`, the stream
  ends with an `abort` chunk and no `error` chunk.
- When `execute` raises, the writer now pushes the `error` chunk at once and
  then waits for the merged streams to end before it closes, as upstream's
  createUIMessageStream does. It used to close at once, so a merge still
  running pushed into the closed stream and raised `Lwt_stream.Closed` out
  of `Lwt.async`, which exits the process by default. A write or merged
  chunk that comes after the stream closed is now dropped.
- A chunk written while the writer's `on_finish` runs is now dropped rather
  than sent after `finish`. The stream still closes only after `on_finish`
  returns. A merged stream's failure is now formatted by `on_error` too.
  When `on_error` itself raises, the error chunk reads "An error occurred."
  and the stream ends normally. The exception used to escape to
  `Lwt.async_exception_hook`, and the stream never closed.
- `Prompt_builder.make_call_options` takes `?abort_signal`.
- `Server_handler.handle_chat` takes `?abort_signal`, which aborts the
  request: the SSE stream ends with an `abort` chunk and `data: [DONE]`. To
  stop the generation when the client disconnects, pass a signal that the web
  server settles on disconnect. Without one, a disconnect stops nothing, as
  before and as upstream, which aborts only when the route passes its
  request's signal as `abortSignal`.

### Mock model (`ai_mock`)

- New `ocaml-ai-sdk.ai_mock` library with `Ai_mock.Language_model`, a
  language model for tests modelled on upstream's `MockLanguageModelV3`. It
  returns canned or computed results and records the options of every call.
  `hang` and `hanging_stream` stand in for a provider that waits until the
  call is aborted.

### OpenRouter provider (`ai_provider_openrouter`)

- `Openrouter_api.provider_error_of_http_response` takes an
  `Http_client.response` instead of a `Cohttp.Response.t`.

## 0.6.3 — 2026-09-08

### Anthropic provider (`ai_provider_anthropic`)

- The `Invalid_argument` raised for an unsupported thinking or effort setting now
  says what to use instead. Passing `Thinking.Enabled` to an adaptive-generation
  model (Fable 5, Mythos 5, Opus 5, Opus 4.8, Sonnet 5) names `Thinking.Adaptive`
  plus `Anthropic_options.effort` as the successor to manual token budgets, and
  explains that the caller picks the effort level because no faithful budget-to-effort
  mapping exists. The adaptive, disabled-thinking, and forced-tool-choice rejections
  got the same treatment. Which inputs are rejected has not changed.
- The effort rejection now names the levels the model does accept, falling back to
  "accepts no effort levels" only when the list is genuinely empty. Every catalog
  model with effort support currently accepts all five levels or none, so today this
  reads the same; it stays correct if a partial-effort model is added.
- `Effort.equal` is now exposed, replacing a polymorphic comparison in the effort check.
- `Anthropic_model.unsupported_effort_message` is exposed so a test can pin the
  partial-effort wording. No catalog model has a partial `effort_levels` list, so that
  branch cannot be reached through `create`; the test drives the builder directly and
  cross-checks the empty-list case against the message `create` actually raises.
- `Thinking.t` in the mli now documents which models accept each constructor, that
  `Adaptive` with an effort level replaces `Enabled`'s budgets, that `Disabled` is not
  universally supported, and that omitting thinking is not the same as disabling it
  (Opus 4.8 and Haiku 4.5 do not think by default, the other adaptive-generation
  models do). It also records that a custom model id has unknown capabilities, so
  manual budgets pass through to the API untouched instead of being rejected.

## 0.6.2 — 2026-08-19

### OpenRouter provider (`ai_provider_openrouter`)

- The `annotations` field on chat messages and stream deltas now decodes an
  explicit JSON `null`. Some OpenAI-compatible servers (vLLM) serialize an
  absent `annotations` as `null` on every response, which previously failed
  with "expected array but got null". This matches OpenAI's own client, which
  types the field as optional. A malformed non-null value is still rejected,
  and the remaining array fields keep the strict spec shape.

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
