# Melange Chat

Full chat application with the frontend compiled from OCaml to JavaScript using Melange.
Demonstrates the `ai-sdk-react` bindings (`useChat`, message parts, tool rendering)
in a pure OCaml/Melange frontend.

## Quick Start

```bash
# Install frontend dependencies (first time only)
npm install

# Start the chat_server backend first
ANTHROPIC_API_KEY=$(passage get anthropic/staging/api_key) dune exec examples/chat_server/main.exe

# Start frontend (in a separate terminal)
npm run dev
```

- Backend: http://localhost:28601/chat (shared with chat_server)
- Frontend: http://localhost:28600

## What It Demonstrates

- Melange-compiled React frontend using `ai-sdk-react` OCaml bindings
- `useChat` hook with `DefaultChatTransport`
- Message parts rendering: text, tool calls (input/output), structured JSON cards
- Tool approval workflow with `addToolApprovalResponse`
- Auto-resubmit via `lastAssistantMessageIsCompleteWithApprovalResponses`

## Testing Checklist

- [ ] "Hello" — basic streaming text response
- [ ] "Search for OCaml tutorials" — search_web tool executes, results render as cards
- [ ] "What's the weather in Paris?" — triggers tool with approval workflow
- [ ] Verify tool cards show tool name, state badge, input, and output sections

## Architecture

- **Frontend**: Melange-compiled OCaml (`.mlx` files) with reason-react
- **Backend**: Uses the `chat_server` example backend (must be running on port 28601)
- **Frontend port**: 28600

## Dependencies

- Requires the `chat_server` backend running at http://localhost:28601
- Cannot run simultaneously with the `chat_server` frontend (both use port 28600)

## Environment Variables

None — the backend handles API keys. Set `ANTHROPIC_API_KEY` on the `chat_server`.
