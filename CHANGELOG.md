# Changelog

All notable changes to this project will be documented in this file.

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
- **Partial JSON parser** — for streaming structured output

### Melange Bindings (`ai-sdk-react`)

- `useChat` and `useCompletion` hook bindings for `@ai-sdk/react`
- All v6 message part types including `data_ui_part`
- `classify` function for part type dispatch
- Module-scoped accessors for ergonomic use from OCaml/Reason

### Examples

- `one_shot`, `streaming`, `tool_use`, `thinking`, `generate`, `stream_chat`
  — standalone CLI examples
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
