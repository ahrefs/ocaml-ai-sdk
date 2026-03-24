# Core SDK Implementation Plan

**Goal:** Implement `ai_core` library with `generate_text`, `stream_text`, UIMessage stream protocol, and cohttp server handler for frontend interop with `useChat()`.

**Design doc:** `docs/plans/2026-03-05-core-sdk-design.md`

**Status:** v1 complete (24 commits on `implement-core_sdk` branch).

**Resolved decisions:**
- Multi-step tool loops in stream_text: YES — implemented
- Structured output (Output API): defer to v2
- Cohttp server handler: YES — `Server_handler.handle_chat` with CORS
- ID generation: simple counter per stream (`txt_1`, `rsn_1`)
- Smooth streaming: defer to v2
- `send_reasoning` default: `true` (reasoning chunks sent unless opted out)
- Request body parsing: supports both v5 `content` and v6 `parts` formats

---

## Task Dependency Graph

```
Group 1: Foundation Types                                      ✅ DONE
  1.1 Core_tool, Text_stream_part, Generate_text_result types
  1.2 Ui_message_chunk type + JSON serialization (all v6 chunk types)
  1.3 Ui_message_stream (SSE encoding + headers)
    │
Group 2: Core Functions                                        ✅ DONE
  2.1 Prompt_builder (resolve_messages, make_call_options, tools_to_provider)
  2.2 generate_text (with multi-step tool loop)
  2.3 stream_text (with multi-step tool loop, background Lwt.async)
    │
Group 3: Frontend Interop                                      ✅ DONE
  3.1 Stream_text_result.to_ui_message_stream + to_ui_message_sse_stream
  3.2 Server_handler (handle_chat, handle_cors_preflight, make_sse_response)
    │
Group 4: Integration                                           ✅ DONE
  4.1 E2E tests with mock provider
  4.2 SSE wire format snapshot tests
  4.3 Final cleanup + v6 interop fixes
```

---

## Modules Implemented

| Module | File | Purpose |
|--------|------|---------|
| `Core_tool` | `core_tool.ml/mli` | Tool definition type (description, parameters, execute) |
| `Generate_text_result` | `generate_text_result.ml/mli` | Result types: tool_call, tool_result, step, t |
| `Text_stream_part` | `text_stream_part.ml/mli` | Internal stream events (13 variants) |
| `Ui_message_chunk` | `ui_message_chunk.ml/mli` | v6 UIMessage protocol chunks (21 variants) + `to_yojson` |
| `Ui_message_stream` | `ui_message_stream.ml/mli` | SSE encoding: `chunk_to_sse`, `done_sse`, `stream_to_sse`, `headers` |
| `Prompt_builder` | `prompt_builder.ml/mli` | Prompt construction, tool conversion, call_options builder |
| `Generate_text` | `generate_text.ml/mli` | Non-streaming text generation with multi-step tool loop |
| `Stream_text` | `stream_text.ml/mli` | Streaming text generation (returns synchronously, fills streams via Lwt.async) |
| `Stream_text_result` | `stream_text_result.ml/mli` | Stream result + `to_ui_message_stream` / `to_ui_message_sse_stream` |
| `Server_handler` | `server_handler.ml/mli` | Cohttp chat endpoint: request parsing, SSE response, CORS |
| `Ai_core` | `ai_core.ml/mli` | Top-level re-exports of all modules |

---

## Key Implementation Details

### UIMessage Chunk Types
All 21 v6 chunk types implemented with correct camelCase JSON field names:
`start`, `finish`, `abort`, `start-step`, `finish-step`, `text-start`, `text-delta`,
`text-end`, `reasoning-start`, `reasoning-delta`, `reasoning-end`, `tool-input-start`,
`tool-input-delta`, `tool-input-available`, `tool-output-available`, `tool-output-error`,
`tool-input-error`, `tool-output-denied`, `source-url`, `source-document`, `file`,
`message-metadata`, `error`, `data-*` (custom).

### Tool_input_start Ordering
The v6 `processUIMessageStream` requires `tool-input-start` before any
`tool-input-delta` for a given tool call. The `to_ui_message_stream` transform
tracks started tool calls via a hashtable and emits `Tool_input_start` on the
first delta or on `Tool_call` if no deltas preceded it.

### stream_text Returns Synchronously
`stream_text` returns a `Stream_text_result.t` synchronously. The actual
streaming happens in a background `Lwt.async` task that fills the streams.
Promises for `usage`, `finish_reason`, and `steps` resolve when the stream
completes. Errors in the background task are emitted as `Error` parts and
also reject the promises.
