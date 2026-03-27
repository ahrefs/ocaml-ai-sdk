# Core SDK Design

> Architectural reference for the Core SDK layer (`ai_core`).
> For current feature status, see `2026-03-26-v2-roadmap.md` and `2026-03-26-v3-roadmap.md`.

## Goal

The Core SDK sits between the provider abstraction (`ai_provider`) and the
frontend. It is the OCaml equivalent of the `ai` package's `generateText`,
`streamText`, and UIMessage stream protocol.

The critical deliverable is **frontend interoperability** — an OCaml server
that speaks the exact SSE wire format that `useChat()` from `@ai-sdk/react`
expects, enabling an OCaml backend with a JavaScript/React frontend.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  JavaScript Frontend (useChat / @ai-sdk/react)          │
│  Consumes: SSE with UIMessage stream protocol v1        │
└─────────────────────┬───────────────────────────────────┘
                      │ HTTP POST → SSE response
                      │ Header: x-vercel-ai-ui-message-stream: v1
┌─────────────────────▼───────────────────────────────────┐
│  Core SDK (ai_core)                                     │
│                                                         │
│  generate_text : high-level non-streaming generation    │
│  stream_text   : high-level streaming generation        │
│  Tool          : tool definition with schema + execute  │
│  UIMessage_stream : SSE encoder for frontend interop    │
│                                                         │
│  Internally uses: Language_model.t from ai_provider     │
└─────────────────────┬───────────────────────────────────┘
                      │ Language_model.generate / stream
┌─────────────────────▼───────────────────────────────────┐
│  Provider Layer (ai_provider + ai_provider_anthropic)   │
└─────────────────────────────────────────────────────────┘
```

---

## UIMessage Stream Protocol

### SSE Wire Format

Each chunk serializes to a JSON object with a `type` field, sent as an SSE data line:

```
data: {"type":"start","messageId":"msg_1"}

data: {"type":"start-step"}

data: {"type":"text-start","id":"txt_1"}

data: {"type":"text-delta","id":"txt_1","delta":"Hello"}

data: {"type":"text-end","id":"txt_1"}

data: {"type":"finish-step"}

data: {"type":"finish","finishReason":"stop"}

data: [DONE]

```

**CRITICAL**: Field names use camelCase in JSON (matching TypeScript SDK)
but snake_case in OCaml types. The `to_json` function handles this mapping.

### Required HTTP Headers

```
content-type: text/event-stream
cache-control: no-cache
connection: keep-alive
x-vercel-ai-ui-message-stream: v1
x-accel-buffering: no
```

### Chunk Type Categories

- **Message lifecycle**: `start`, `finish`, `abort`, `message-metadata`
- **Step boundaries**: `start-step`, `finish-step`
- **Text streaming**: `text-start`, `text-delta`, `text-end`
- **Reasoning streaming**: `reasoning-start`, `reasoning-delta`, `reasoning-end`
- **Tool interaction**: `tool-input-start`, `tool-input-delta`, `tool-input-available`, `tool-output-available`, `tool-output-error`, `tool-input-error`, `tool-output-denied`
- **Sources**: `source-url`, `source-document`
- **Files**: `file`
- **Custom data**: `data-{type}` (with optional `transient` flag)
- **Error**: `error`

---

## Stream Transformation Pipeline

### Provider Stream → Internal Events → UIMessage Chunks

Two transformation stages connect the provider's raw stream to the frontend:

**Stage 1: Provider → Text_stream_part (internal)**

```
Provider Stream_part.t          →  Text_stream_part.t
─────────────────────────────────────────────────────
Stream_start                    →  Start, Start_step
Text { text }                   →  Text_start (first), Text_delta
Reasoning { text }              →  Reasoning_start (first), Reasoning_delta
Tool_call_delta { ... }         →  Tool_call_delta (accumulate args)
Tool_call_finish { id }         →  Tool_call (complete, with accumulated args)
Finish { reason; usage }        →  Finish_step (+ tool exec if needed)
                                   Then either loop or Finish
Error { error }                 →  Error
```

**Stage 2: Text_stream_part → Ui_message_chunk (frontend)**

```
Text_stream_part.t              →  Ui_message_chunk.t
─────────────────────────────────────────────────────
Start                           →  (absorbed — Start emitted separately with message_id)
Start_step                      →  Start_step
Text_start { id }               →  Text_start { id }
Text_delta { text; id }         →  Text_delta { id; delta = text }
Text_end { id }                 →  Text_end { id }
Reasoning_start { id }          →  Reasoning_start { id }  (if send_reasoning)
Reasoning_delta { text; id }    →  Reasoning_delta { id; delta = text }
Reasoning_end { id }            →  Reasoning_end { id }
Tool_call_delta { ... }         →  Tool_input_start (on first delta per tool_call_id)
                                   + Tool_input_delta { ... }
Tool_call { id; name; args }    →  Tool_input_start (if no prior deltas)
                                   + Tool_input_available { id; name; input = args }
Tool_result { id; result; ... } →  Tool_output_available { id; output = result }
                                   OR Tool_output_error { id; error_text } (if is_error)
Source { source_id; url; ... }  →  Source_url { source_id; url; title }
File { url; media_type }        →  File { url; media_type }
Finish_step { ... }             →  Finish_step
Finish { reason; usage }        →  Finish { finish_reason }
Error { error }                 →  Error { error_text }
```

**CRITICAL:** `Tool_input_start` must be emitted before any `Tool_input_delta`
for a given tool call. The `to_ui_message_stream` function tracks which tool
calls have started and emits `Tool_input_start` on the first delta or on
`Tool_call` if no deltas preceded it. The v6 `processUIMessageStream` throws
if it receives a `tool-input-delta` without a preceding `tool-input-start`.

---

## generate_text Flow

```
1. Build initial prompt:
   - If prompt given → [System(system); User([Text(prompt)])]
   - If messages given → prepend System if system is set
   - Convert tools to Tool.t list for Call_options

2. Step loop (max_steps iterations):
   a. Call Language_model.generate with current messages
   b. Parse result.content into text + tool_calls + reasoning
   c. If no tool calls or tool_choice = None_ → break
   d. Execute each tool call:
      - Find tool by name in tool map
      - Call tool.execute with args JSON
      - Catch exceptions → tool_result with is_error=true
   e. Append assistant message (with tool calls) to messages
   f. Append tool results as Tool message
   g. Record step, call on_step_finish callback
   h. Continue loop

3. Aggregate results:
   - Concatenate text from all steps
   - Concatenate reasoning from all steps
   - Sum usage across steps
```

---

## stream_text Flow

`stream_text` returns **synchronously** (not `Lwt.t`). The stream
is consumed asynchronously. This matches the TypeScript SDK's behavior.

```
1. Build initial prompt (same as generate_text)

2. Create output streams:
   - full_stream (Text_stream_part.t Lwt_stream.t) with push function
   - text_stream derived by filtering full_stream for text deltas

3. Start background task (Lwt.async):
   a. Emit Start, Start_step
   b. Call Language_model.stream with current messages
   c. Consume provider stream parts, transforming to Text_stream_part
   d. On Finish with pending tool calls:
      i.  Emit Tool_call for each complete call
      ii. Execute tools
      iii. Emit Tool_result for each
      iv. Emit Finish_step
      v.  If should continue: go back to step b with updated messages
      vi. Otherwise: emit Finish, close stream
   e. On Finish (no tools): emit Finish_step, Finish, close

4. Return Stream_text_result with streams + promises for final values
```

---

## Request Parsing (v6 UIMessage format)

The server handler parses v6 `parts`-based messages from `useChat()`.
Each message has a `role` and a `parts` array of typed content.

Supported part types:
- `text` → `Prompt.User.Text` / `Prompt.Assistant.Text`
- `file` (with `mediaType` + `url` or `data`) → `Prompt.User.File` / `Prompt.Assistant.File`
- `reasoning` → `Prompt.Assistant.Reasoning`
- `tool-{name}` / `dynamic-tool` → `Prompt.Assistant.Tool_call` + `Prompt.Tool` (result)
- `step-start`, `source` → skipped (rendering hints, not model input)

Tool invocation parts carry a `state` field that determines whether a
tool result is generated:
- `output-available` → success result
- `output-error` → error result
- `output-denied` → denied error result
- `input-streaming`, `input-available`, `approval-requested`, `approval-responded` → tool call only, no result

---

## Design Decisions

| Decision | Resolution |
|----------|-----------|
| Multi-step tool loops in `stream_text` | Background `Lwt.async` step loop |
| `stream_text` return type | Synchronous (not `Lwt.t`) — streams filled async |
| ID generation for stream parts | Simple counter per stream (`txt_1`, `rsn_1`) — deterministic and testable |
| `send_reasoning` default | Defaults to `true` (matches Anthropic thinking visibility) |
| Tool result serialization | All tools return `Yojson.Basic.t` directly (no existential wrapper) |
| Request parsing | v6 `parts` array only (v5 `content` string removed) |
| Multi-turn conversation | Caller's responsibility — Core SDK is stateless (matches upstream) |
