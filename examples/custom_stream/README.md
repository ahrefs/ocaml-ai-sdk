# Custom Stream Composition

Demonstrates `create_ui_message_stream` for composing custom SSE streams that interleave
Data parts with LLM output. Shows how to write custom metadata alongside model responses.

## Quick Start

```bash
# Install frontend dependencies (first time only)
npm install

# Start backend
ANTHROPIC_API_KEY=$(passage get anthropic/staging/api_key) dune exec examples/custom_stream/main.exe

# Start frontend (in a separate terminal)
npm run dev
```

- Backend: http://localhost:28602/chat
- Frontend: http://localhost:28603

## What It Demonstrates

- Custom stream composition using `Ui_message_stream_writer`
- Writing Data parts (`status: generating`, `status: complete`) alongside LLM output
- Data reconciliation — same id updates the part on the client rather than creating duplicates
- Merging a `stream_text` result into a composed stream via `merge`
- Creating HTTP responses from composed streams

## Testing Checklist

- [ ] Send any message — response streams with "status: complete" badge visible
- [ ] Verify the status badge appears in the assistant message alongside text
- [ ] Check that streaming works smoothly without interruptions

## Architecture

- **Backend**: OCaml cohttp server at port 28602
- **Frontend**: Melange-compiled React app served by Hono at port 28603
- **Stream flow**: Server writes "generating" data part → merges LLM stream → writes "complete" data part

## Environment Variables

- `ANTHROPIC_API_KEY` — required
