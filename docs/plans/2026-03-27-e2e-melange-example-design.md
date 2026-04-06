# End-to-End Melange Example App

> Design for a single-page Melange app demonstrating all major SDK features.
> Modeled after Vercel's `examples/ai-e2e-next`, scoped to Anthropic + OpenAI.

## Overview

A single React SPA built with Melange + reason-react, served by a cohttp backend.
One sidebar, 11 demo pages (7 working, 4 stubs). Anthropic by default, with a provider toggle.
Frontend patterns follow the upstream TypeScript example closely.

### Known Limitations

- **reason-react-ppx 0.15.0 + MLX dialect**: The PPX does not generate `makeProps`
  for MLX files, so custom components with labeled arguments cannot use JSX syntax
  (`<Component prop=... />`). Workaround: components with props use plain functions
  (`render ~prop ...`) instead of `[@react.component]`; propless components use
  `[@react.component] let make ()` and are called via `React.createElement`.
- **Client-side tools**: The `addToolOutput` + `sendAutomaticallyWhen` pattern
  doesn't round-trip correctly through `parse_messages_from_body` — Anthropic
  rejects the re-sent conversation as "assistant message prefill". Needs proper
  tool approval protocol on the server side.

## Directory Structure

```
examples/ai-e2e/
├── dune                        # melange.emit + bundle rule
├── package.json                # @ai-sdk/react, ai, react, esbuild
├── build.js                    # esbuild bundler (same pattern as melange_chat)
├── index.html                  # entry HTML with #root div
├── main.mlx                    # ReactDOM root + router mount
├── router.ml                   # hash-based client-side router
├── provider_context.ml         # React context for provider selection
├── chat_layout.mlx             # shared chat UI shell (render function)
├── chat_message.mlx            # shared message part renderer (render function)
├── sidebar.mlx                 # navigation sidebar (render function)
├── basic_chat.mlx              # 1. basic streaming chat
├── tool_use.mlx                # 2. server-side tool use
├── reasoning.mlx               # 3. extended thinking / reasoning
├── structured_output.mlx       # 4. structured output with schema
├── abort_stop.mlx              # 5. abort mid-stream
├── retry_regenerate.mlx        # 6. retry / regenerate
├── client_tools.mlx            # 7. client-side tools (stub)
├── completion.mlx              # 8. useCompletion hook
├── tool_approval.mlx           # 9. tool approval (stub)
├── web_search.mlx              # 10. provider web search (stub)
├── file_attachments.mlx        # 11. file attachments (stub)
└── server/
    ├── dune                    # executable config
    └── main.ml                 # cohttp backend with all endpoints
```

Note: all `.mlx` files are in a flat directory (no subdirectories) because
`melange.emit` doesn't support `include_subdirs` with the MLX dialect's
separate server executable in a child directory.

## Implementation Plan

### Step 1: Project scaffolding

Create the directory structure, `dune` files, `package.json`, `build.js`,
and `index.html`. Mirror the `melange_chat` build pattern.

**Files:**
- `examples/ai-e2e/dune` — `melange.emit` targeting `output/`, alias `ai_e2e`,
  libraries: `ai_sdk_react reason-react`, ppx: `melange.ppx reason-react-ppx`
- `examples/ai-e2e/package.json` — deps: `@ai-sdk/react`, `ai`, `react`, `react-dom`;
  devDeps: `esbuild`
- `examples/ai-e2e/build.js` — esbuild config pointing at melange output
- `examples/ai-e2e/index.html` — minimal HTML loading `dist/bundle.js` with `#root` div
- `examples/ai-e2e/main.mlx` — `ReactDOM.Client.render` mounting `<App />`

### Step 2: Router and sidebar

Simple hash-based routing so each demo is a distinct "page".

**`router.ml`:**
```ocaml
type route =
  | Basic_chat
  | Tool_use
  | Reasoning
  | Structured_output
  | Abort_stop
  | Retry_regenerate
  | Client_tools
  | Completion
  | Tool_approval
  | Web_search
  | File_attachments

val route_of_hash : string -> route
val hash_of_route : route -> string
val route_label : route -> string
val is_stub : route -> bool
val all_routes : route list
```

**`sidebar.mlx`:**
- Renders `all_routes` as nav links
- Highlights active route
- Stubs shown with "(coming soon)" badge and muted styling

**`main.mlx`:**
- `use_state` for current route, `use_effect` for `hashchange` listener
- Match on route to render the correct demo component
- Wrap in flex layout: sidebar | demo content

### Step 3: Shared components — message renderer

**`components/message.mlx`:**

Renders a single `ui_message`. Iterates `ui_message_parts` and matches with `classify`:

- `Text` — `<div>` with `white-space: pre-wrap`. (Upstream uses `streamdown`
  for markdown rendering; we use plain text, can add markdown renderer later.)
- `Reasoning` — `<details>` with `<summary>Thinking...</summary>` and the
  reasoning text inside. Left border accent `#9333ea` (purple). Matches
  upstream's `<Reasoning>` component.
- `Tool_call` — Monospace card showing:
  - Tool name in `<strong>`
  - State badge: "Calling..." (yellow), "Done" (green), "Error" (red)
  - Collapsible input JSON
  - Output JSON (green) or error text (red)
  - Matches upstream's `components/tool/` rendering pattern
- `Source_url` — Clickable `<a>` with title, grouped at message end
- `File` — `<img>` for image media types, generic file badge otherwise
- `Step_start` — Thin `<hr>` divider between multi-step outputs
- `Unknown` — Ignored (silent skip)

**`components/chat_layout.mlx`:**

Reusable chat chrome. Props:
- `~endpoint : string` — API path (e.g. `"/api/chat/basic"`)
- `~children : Use_chat.t -> React.element` — render slot for custom controls
- `~on_tool_call : (Js.Json.t -> unit) option` — forwarded to `useChat`

Internally:
- Creates `DefaultChatTransport` with the endpoint
- Calls `use_chat` with transport + optional callbacks
- Renders: error banner, scrollable message list using `Message.make`,
  input form with submit, passes `Use_chat.t` to children for custom controls
- Auto-scrolls to bottom on new messages via `useEffect` + ref

### Step 4: Backend server

**`examples/ai-e2e/server/main.ml`:**

Single cohttp server on port 28601 with route dispatch.

```
POST /api/chat/basic        — stream_text, no tools, no reasoning
POST /api/chat/tools        — stream_text + weather/search tools, max_steps:5
POST /api/chat/reasoning    — stream_text + send_reasoning:true + provider thinking options
POST /api/chat/structured   — stream_text + Output.object_ with schema
POST /api/chat/client-tools — stream_text, no server tools, system prompt asks model to request client actions
POST /api/chat/completion   — plain text stream for useCompletion (see below)
POST /api/chat/approval     — same as /tools for now (stub)
POST /api/chat/web-search   — same as /basic for now (stub)
OPTIONS /api/chat/*         — CORS preflight
GET /*                      — serve static files from dist/
```

**Provider selection:** Read `X-Provider` header from request, default to `"anthropic"`.
Frontend sends this via `DefaultChatTransport` headers.

**Model selection:** Map provider string to model:
- `"anthropic"` → `Ai_provider_anthropic.model "claude-sonnet-4-6"`
- `"openai"` → `Ai_provider_openai.model "gpt-4o"`

**Tools** (reused from existing `chat_server` pattern):
- `get_weather` — city → temperature/condition (fake data)
- `search_web` — query → simulated results

**Structured output schema:**
```ocaml
type data_point = { label : string; value : string } [@@deriving jsonschema]
type structured_response = { summary : string; data : data_point list } [@@deriving jsonschema]
```

**Reasoning endpoint:** Pass `provider_options` with thinking enabled for Anthropic.
For OpenAI, pass reasoning level in provider options.

**Completion endpoint** (`/api/chat/completion`):

`useCompletion` with `stream_protocol:"text"` expects a plain `text/plain`
streaming response — just raw text chunks, no SSE framing. Implementation:

```ocaml
val handle_completion :
  model:Ai_provider.Language_model.t ->
  ?system:string ->
  Cohttp_lwt_unix.Server.conn ->
  Cohttp.Request.t ->
  Cohttp_lwt.Body.t ->
  (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t
```

Parses `{ prompt: string }` from body, calls `stream_text ~prompt`,
streams `text_stream` as chunked `text/plain` response. ~20 lines.

**Static file serving:** Serve `index.html` for GET `/` and bundled JS
from `dist/`. Uses `Cohttp_lwt_unix.Server` with file reads.

**dune:**
```
(executable
 (name main)
 (libraries
  ai_provider ai_provider_anthropic ai_provider_openai ai_core
  lwt lwt.unix cohttp cohttp-lwt cohttp-lwt-unix
  yojson melange-json-native ppx_deriving_jsonschema.runtime)
 (preprocess
  (pps lwt_ppx melange-json-native.ppx ppx_deriving_jsonschema)))
```

### Step 5: Demos 1-2 — Basic Chat and Tool Use

**`demos/basic_chat.mlx`:**
```
ChatLayout endpoint="/api/chat/basic" with no extra controls.
```

**`demos/tool_use.mlx`:**
```
ChatLayout endpoint="/api/chat/tools" with no extra controls.
Tool visualization handled by shared message renderer.
```

These two validate the full stack works end to end.

### Step 6: Demos 3-4 — Reasoning and Structured Output

**`demos/reasoning.mlx`:**
```
ChatLayout endpoint="/api/chat/reasoning" with no extra controls.
Reasoning parts rendered by shared message renderer as collapsible blocks.
```

**`demos/structured_output.mlx`:**
```
ChatLayout endpoint="/api/chat/structured".
The message renderer detects JSON text parts matching the schema
and renders them as formatted key-value cards instead of raw text.
```

### Step 7: Demos 5-6 — Abort/Stop and Retry/Regenerate

**`demos/abort_stop.mlx`:**
```
ChatLayout endpoint="/api/chat/basic" with children callback:
- When status = Streaming, show "Stop" button calling Use_chat.stop
- When status = Ready, show normal "Send" button
Matches upstream's Send/Stop button swap pattern.
```

**`demos/retry_regenerate.mlx`:**
```
ChatLayout endpoint="/api/chat/basic" with children callback:
- On last assistant message, show "Regenerate" icon button calling Use_chat.regenerate
- Matches upstream's refresh icon on hover pattern.
```

### Step 8: Demo 7 — Client-side Tools (stub)

Moved to stub. The `addToolOutput` + `sendAutomaticallyWhen` approach doesn't
round-trip correctly — after the client submits tool output, the SDK re-sends
the conversation but `parse_messages_from_body` doesn't reconstruct the message
sequence correctly for Anthropic (ends with assistant turn instead of user turn).

Needs proper tool approval protocol: `needsApproval` flag on tools, server-side
approval request/response events in the UIMessage stream, and
`addToolApprovalResponse` on the client. The UI patterns (approval dialog,
tool output submission) are implemented in the stub's commented code.

### Step 9: Demo 8 — useCompletion

**`demos/completion.mlx`:**

Different hook — `Use_completion.use_completion` instead of `useChat`.

UI:
- Single textarea for prompt input
- "Complete" button calling `Use_completion.complete`
- Completion text area (read-only) showing streamed result
- "Stop" button when loading, "Clear" button when done
- No message history — single prompt → single completion

Endpoint: `/api/chat/completion` with `stream_protocol:"text"`.

### Step 10: Demos 9-11 — Stubs

Each stub demo renders:
- The correct UI shell (same layout as a working demo)
- A banner: "This feature requires SDK capabilities not yet implemented"
- Commented OCaml code showing what the implementation would look like
- A list of what's needed (e.g. "Needs: tool approval protocol in server_handler")

**`client_tools.mlx`:**
```
(* Needs: tool approval protocol — needsApproval flag on tool,
   approval request stream event, approval response handling.
   Alternative: onToolCall returning a Promise<result> for automatic tools.
   UI patterns (approval dialog, tool output submission) are ready. *)
```

**`tool_approval.mlx`:**
```
(* Needs: server-side approval protocol — needsApproval flag on tool,
   approval request stream event, approval response handling *)
```

**`web_search.mlx`:**
```
(* Needs: provider-specific tool passthrough — Anthropic webSearch_20250305,
   OpenAI webSearch built-in tool *)
```

**`file_attachments.mlx`:**
```
(* Needs: file upload endpoint, file part in message protocol,
   multipart request support in server_handler *)
```

### Step 11: Provider toggle

Add a provider selector to the sidebar:
- Dropdown or toggle: "Anthropic" / "OpenAI"
- Stored in React state, passed as context
- `ChatLayout` reads provider from context and adds `X-Provider` header
  to the `DefaultChatTransport`
- Switching provider clears the current conversation

### Step 12: Polish and verification

- Verify all 8 working demos function end-to-end
- Verify stubs render correctly with banners
- Verify provider toggle works for both Anthropic and OpenAI
- Test abort/stop and regenerate flows
- Ensure the build pipeline works: `dune build @ai_e2e && node build.js`
- Run `ocamlformat` on all `.ml` files

## Feature Matrix

| # | Demo | Endpoint | Hook | Backend | Status |
|---|------|----------|------|---------|--------|
| 1 | Basic Chat | `/api/chat/basic` | `useChat` | `stream_text` | Working |
| 2 | Tool Use | `/api/chat/tools` | `useChat` | `stream_text` + tools | Working |
| 3 | Reasoning | `/api/chat/reasoning` | `useChat` | `stream_text` + reasoning | Working |
| 4 | Structured Output | `/api/chat/structured` | `useChat` | `stream_text` + output | Working |
| 5 | Abort / Stop | `/api/chat/basic` | `useChat` + `stop` | `stream_text` | Working |
| 6 | Retry / Regenerate | `/api/chat/basic` | `useChat` + `regenerate` | `stream_text` | Working |
| 7 | Client Tools | `/api/chat/client-tools` | `useChat` + `addToolOutput` | Needs tool approval protocol | Stub |
| 8 | Completion | `/api/chat/completion` | `useCompletion` | `stream_text` (text) | Working |
| 9 | Tool Approval | `/api/chat/approval` | `useChat` + approval | Needs tool approval protocol | Stub |
| 10 | Web Search | `/api/chat/web-search` | `useChat` | Needs provider tool passthrough | Stub |
| 11 | File Attachments | `/api/chat/basic` | `useChat` + files | Needs file upload support | Stub |

## Dependencies

**Frontend (npm):**
- `@ai-sdk/react` ^3.0.118 (or matching v7 beta)
- `ai` ^6.0.0 (or matching v7 beta)
- `react` ^19.0.0
- `react-dom` ^19.0.0
- `esbuild` (dev)

**Backend (opam):** No new dependencies beyond what `chat_server` uses.

**Melange (dune):** `ai_sdk_react`, `reason-react` — same as `melange_chat`.

## Running

```bash
# One-time setup
cd examples/ai-e2e && npm install

# Build and run
export ANTHROPIC_API_KEY=sk-...
dune exec examples/ai-e2e/server/main.exe

# In another terminal (or use the build alias)
cd examples/ai-e2e && npm run build

# Open http://localhost:28601
```
