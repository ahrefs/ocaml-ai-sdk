# ocaml-ai-sdk

Type-safe, provider-agnostic AI model abstraction for OCaml, inspired by the [Vercel AI SDK](https://sdk.vercel.ai). Targets wire compatibility with AI SDK v6 so you can pair an OCaml backend with `@ai-sdk/react` frontends.

## Libraries

| Library | opam lib | Description |
|---------|----------|-------------|
| `ai_provider` | `ocaml-ai-sdk.ai_provider` | Provider abstraction — language model module types, tool definitions, prompt types, GADT-based provider options |
| `ai_provider_anthropic` | `ocaml-ai-sdk.ai_provider_anthropic` | Anthropic Messages API — streaming SSE, thinking, cache control, full Claude model catalog |
| `ai_provider_openai` | `ocaml-ai-sdk.ai_provider_openai` | OpenAI Chat Completions API — streaming SSE, tool calling with strict mode, GPT-4o/o1/o3/o4-mini catalog |
| `ai_core` | `ocaml-ai-sdk.ai_core` | Core SDK — `generate_text`, `stream_text` (with tool loops), UIMessage stream protocol, server handler, structured output |
| `ai_sdk_react` | `ai-sdk-react.ai_sdk_react` | Melange bindings for `@ai-sdk/react` — `useChat`, `useCompletion`, v6 part types |

## Quick start

```
opam install ocaml-ai-sdk
```

### One-shot generation

```ocaml
open Ai_core
open Ai_provider_anthropic

let () =
  Lwt_main.run @@
  let model = Anthropic.create_model "claude-sonnet-4-20250514" in
  let%lwt result = Generate_text.generate ~model ~prompt:"Say hello" () in
  Lwt_io.printl result.text
```

### Streaming

```ocaml
let () =
  Lwt_main.run @@
  let model = Anthropic.create_model "claude-sonnet-4-20250514" in
  let%lwt result = Stream_text.stream ~model ~prompt:"Tell me a joke" () in
  Lwt_stream.iter_s Lwt_io.printl result.text_stream
```

### Chat server (with UIMessage protocol)

```ocaml
let handler = Server_handler.create ~model ()
(* Serves SSE responses compatible with useChat() from @ai-sdk/react *)
```

See [`examples/`](examples/) for complete runnable demos including tool use, thinking, structured output, and full-stack Melange apps.

## Architecture

```
ai_provider          Provider abstraction (module types, GADT options)
├── ai_provider_anthropic   Anthropic implementation
├── ai_provider_openai      OpenAI implementation
└── ai_core                 Core SDK (generate, stream, UIMessage protocol)
```

**Key design choices:**

- **Provider options** use an extensible GADT (`type _ key = ..`) for compile-time type-safe provider-specific settings (e.g. thinking budget, cache control)
- **Prompt types** are role-constrained variants — `System` accepts only strings, `User` accepts text + files, etc.
- **Streaming** uses `Lwt_stream.t` — `stream_text` returns synchronously with streams populated by a background Lwt task
- **UIMessage protocol** emits SSE chunks matching the `ai@6` Zod schemas exactly, so `useChat()` works without adaptation

## AI SDK v6 compatibility

The UIMessage stream protocol (`x-vercel-ai-ui-message-stream: v1`) is wire-compatible with:

- `@ai-sdk/react` 3.x (`useChat`, `useCompletion`)
- `ai` 6.x (core SDK)

All chunk types are supported: text, reasoning, tool call (start/delta/result), source, file, data, error, finish message/step.

## Requirements

- OCaml >= 4.14
- For Melange bindings: `melange` >= 4.0.0

## Development

```sh
make build    # Build all libraries
make test     # Run test suites
make dev      # Watch mode
```

## License

MIT
