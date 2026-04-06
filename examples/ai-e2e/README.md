# AI SDK E2E Examples

Single-page Melange + reason-react app demonstrating all major OCaml AI SDK features.
Modeled after Vercel's `ai-e2e-next` reference app.

## Quick Start

```bash
# Install frontend dependencies (first time only)
npm install

# Build frontend (Melange + esbuild)
npm run dev

# Start server (in a separate terminal)
ANTHROPIC_API_KEY=$(passage get anthropic/staging/api_key) dune exec examples/ai-e2e/server/main.exe
```

Open http://localhost:28601 in your browser.

## Demos

| Demo | Route | What it tests |
|------|-------|---------------|
| Basic Chat | `#basic-chat` | Streaming text with `useChat` |
| Tool Use | `#tool-use` | Server-side tools (weather, search) with auto-execution |
| Reasoning | `#reasoning` | Extended thinking with collapsible thought process |
| Structured Output | `#structured-output` | JSON schema output with card rendering |
| Abort / Stop | `#abort-stop` | Stop button to halt generation mid-stream |
| Retry / Regenerate | `#retry-regenerate` | Regenerate the last assistant response |
| Client-side Tools | `#client-tools` | Client tool (location) + server tool with approval (weather) |
| Completion | `#completion` | Text completion with `useCompletion` |
| Tool Approval | `#tool-approval` | Human-in-the-loop approve/deny for tool execution |
| Web Search | `#web-search` | Stub — coming soon |
| File Attachments | `#file-attachments` | Stub — coming soon |

## Testing Checklist

- [ ] Basic Chat: send a message, verify streaming response
- [ ] Tool Use: "What's the weather in Tokyo?" — tool card with input/output
- [ ] Reasoning: ask a math question — collapsible "Thought process" section
- [ ] Structured Output: "Tell me about Paris" — should render as formatted card
- [ ] Abort / Stop: send a long prompt, click "Stop generating"
- [ ] Retry / Regenerate: send a message, click "Regenerate"
- [ ] Client Tools: "What's the weather here?" — approve location, then approve weather
- [ ] Completion: type a prompt, click "Complete"
- [ ] Tool Approval: "What's the weather in London?" — approve/deny buttons appear
- [ ] Provider toggle: switch between Anthropic and OpenAI in the sidebar

## Architecture

- **Frontend**: Melange-compiled OCaml (`.mlx` files) with reason-react
- **Backend**: cohttp server with per-demo endpoints (`/api/chat/basic`, `/api/chat/tools`, etc.)
- **Port**: 28601 (serves both API and static files)
- **Provider selection**: `X-Provider` header (set via sidebar toggle)

## Server Endpoints

| Endpoint | Description |
|----------|-------------|
| `POST /api/chat/basic` | Basic streaming chat |
| `POST /api/chat/tools` | Tool use (weather + search) |
| `POST /api/chat/reasoning` | Extended thinking (Anthropic) |
| `POST /api/chat/structured` | Structured JSON output |
| `POST /api/chat/client-tools` | Client-side + server tools |
| `POST /api/chat/completion` | Text completion |
| `POST /api/chat/approval` | Tool approval workflow |
| `POST /api/chat/web-search` | Web search (stub) |

## Environment Variables

- `ANTHROPIC_API_KEY` — required for Anthropic provider
- `OPENAI_API_KEY` — required for OpenAI provider
