# ocaml-ai-sdk

Type-safe, provider-agnostic AI model abstraction for OCaml, inspired by the [Vercel AI SDK](https://sdk.vercel.ai). Targets wire compatibility with AI SDK v6 so you can pair an OCaml backend with `@ai-sdk/react` frontends.

## Libraries

| Library | opam lib | Description |
|---------|----------|-------------|
| `ai_provider` | `ocaml-ai-sdk.ai_provider` | Provider abstraction — language model module types, tool definitions, prompt types, GADT-based provider options |
| `ai_provider_anthropic` | `ocaml-ai-sdk.ai_provider_anthropic` | Anthropic Messages API — streaming SSE, thinking, cache control, Claude 4.6+ model catalog |
| `ai_provider_openai` | `ocaml-ai-sdk.ai_provider_openai` | OpenAI Chat Completions API — streaming SSE, tool calling with strict mode, GPT-4o/o1/o3/o4-mini catalog |
| `ai_provider_openrouter` | `ocaml-ai-sdk.ai_provider_openrouter` | OpenRouter Chat Completions API — model routing, provider preferences, reasoning, web search, usage accounting, prompt caching |
| `ai_core` | `ocaml-ai-sdk.ai_core` | Core SDK — `generate_text`, `stream_text` (with tool loops), UIMessage stream protocol, server handler, structured output |
| `ai_mock` | `ocaml-ai-sdk.ai_mock` | Mock language model for tests, including models that hang until aborted |
| `ai_sdk_react` | `ai-sdk-react.ai_sdk_react` | Melange bindings for `@ai-sdk/react` — `useChat`, `useCompletion`, v6 part types |

## Quick start

```
opam install ocaml-ai-sdk
```

### One-shot generation

```ocaml
let () =
  Lwt_main.run @@
  let model = Ai_provider_anthropic.model "claude-sonnet-4-6" in
  let%lwt result = Ai_core.Generate_text.generate_text ~model ~prompt:"Say hello" () in
  Lwt_io.printl result.text
```

### Streaming

```ocaml
let () =
  Lwt_main.run @@
  let model = Ai_provider_anthropic.model "claude-sonnet-4-6" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Tell me a joke" () in
  Lwt_stream.iter_s Lwt_io.print result.text_stream
```

### Chat server (with UIMessage protocol)

`Server_handler.handle_chat` turns a `useChat()` request body into an SSE
response. The response is a plain record (status, headers, body stream), so it
works with any web server. With cohttp:

```ocaml
let respond (r : Ai_core.Server_handler.response) =
  Cohttp_lwt_unix.Server.respond ~status:(Cohttp.Code.status_of_code r.status)
    ~headers:(Cohttp.Header.of_list r.headers) ~body:(Cohttp_lwt.Body.of_stream r.body) ()

let callback _conn _req body =
  let%lwt body = Cohttp_lwt.Body.to_string body in
  respond (Ai_core.Server_handler.handle_chat ~model body)
```

To inspect or change the request before generating, parse it with
`Server_handler.parse_chat_request` and call `Stream_text.stream_text` yourself.

### Cancellation

Pass an `Ai_provider.Abort_signal.t` to stop a call. Tools get the same signal
in their `execute` options, and `on_abort` receives the steps recorded before
the abort, so their usage can still be counted:

```ocaml
let say_hello ~model =
  Ai_provider.Abort_signal.with_timeout 30. (fun abort_signal ->
    Ai_core.Generate_text.generate_text ~model ~prompt:"Say hello" ~abort_signal ())
```

See [the cancellation guide](docs/guides/cancellation.md) for `Lwt.cancel`,
combining signals, `stream_text` aborts and stopping generation when a web
client disconnects.

See [`examples/`](examples/) for complete runnable demos including tool use, thinking, structured output, OpenRouter prompt caching, and full-stack Melange apps.

## Architecture

```
ai_provider          Provider abstraction (module types, GADT options)
├── ai_provider_anthropic   Anthropic implementation
├── ai_provider_openai      OpenAI implementation
├── ai_provider_openrouter  OpenRouter implementation
└── ai_core                 Core SDK (generate, stream, UIMessage protocol)
```

**Key design choices:**

- **Provider options** use an extensible GADT (`type _ key = ..`) for compile-time type-safe provider-specific settings (e.g. thinking budget, cache control, OpenRouter routing)
- **Prompt types** are role-constrained variants — `System` accepts only strings, `User` accepts text + files, etc.
- **Streaming** uses `Lwt_stream.t` — `stream_text` returns synchronously with streams populated by a background Lwt task
- **UIMessage protocol** emits SSE chunks matching the `ai@6` Zod schemas exactly, so `useChat()` works without adaptation

### Anthropic thinking

`Anthropic_options.thinking = None` omits the `thinking` request field. Use
`Some Thinking.Disabled` to explicitly disable thinking on models that default
to it; `Adaptive` and `Enabled` select the corresponding Anthropic modes.
`effort` is independent and is serialized under `output_config`.

When forwarding Anthropic reasoning blocks, preserve their provider metadata
signature. Omitted-display thinking can have empty text, but its signature is
required for multi-turn and tool-loop resubmission.

## AI SDK v6 compatibility

The UIMessage stream protocol (`x-vercel-ai-ui-message-stream: v1`) is wire-compatible with:

- `@ai-sdk/react` 3.x (`useChat`, `useCompletion`)
- `ai` 6.x (core SDK)

All chunk types are supported: text, reasoning, tool call (start/delta/result), source, file, data, error, finish message/step.

## Requirements

- OCaml >= 4.14
- libcurl (the system package; opam installs it through `conf-libcurl`)
- For Melange bindings: `melange` >= 4.0.0

## Development

```sh
make build    # Build all libraries
make test     # Run test suites
make dev      # Watch mode
```

## License

MIT
