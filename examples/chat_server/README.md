# Chat Server

Multi-tool chat agent with structured output. Demonstrates the Core SDK's tool execution,
approval workflow, and UIMessage stream protocol for `useChat()` interop.

## Quick Start

```bash
# Install frontend dependencies (first time only)
npm install

# Start backend
ANTHROPIC_API_KEY=$(passage get anthropic/staging/api_key) dune exec examples/chat_server/main.exe

# Start frontend (in a separate terminal)
npm run dev
```

- Backend: http://localhost:28601/chat
- Frontend: http://localhost:28600

## What It Demonstrates

- Multiple tools (`get_weather`, `search_web`) with JSON Schema derived from OCaml types
- Structured output (`Output.object_`) with schema validation
- Multi-step tool execution (agent loop with `max_steps:5`)
- Tool approval workflow (`get_weather` requires approval)
- UIMessage stream protocol v1 for `@ai-sdk/react` `useChat()` interop
- Provider selection via `AI_PROVIDER` environment variable

## Testing Checklist

- [ ] "Search for OCaml" — search_web executes immediately, results display
- [ ] "What's the weather in Paris?" — get_weather triggers approval request
- [ ] Basic conversation — streaming text response
- [ ] Set `AI_PROVIDER=openai` — verify OpenAI provider works

## Architecture

- **Backend**: OCaml cohttp server at port 28601
- **Frontend**: React JSX app served by Hono at port 28600
- **Tools**: `get_weather` (with approval), `search_web` (immediate execution)
- **Model**: `claude-sonnet-4-6` (Anthropic) or `gpt-4o` (OpenAI)

## Environment Variables

- `ANTHROPIC_API_KEY` — required (default provider)
- `AI_PROVIDER=openai` — switch to OpenAI
- `OPENAI_API_KEY` — required when using OpenAI

## Testing with curl

```bash
curl -N -X POST http://localhost:28601/chat \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","parts":[{"type":"text","text":"What is the weather in Paris?"}]}]}'
```
