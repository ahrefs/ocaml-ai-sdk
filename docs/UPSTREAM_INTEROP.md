# Upstream AI SDK v6 Interop Rules

**MUST READ before any feature work or debugging on the UIMessage protocol, SSE chunks, request parsing, or tool workflows.**

## Wire Format Is a Contract

The frontend (`ai@6` / `@ai-sdk/react@3.x`) validates every SSE chunk with `z.strictObject()` Zod schemas. Any deviation — extra fields, missing fields, wrong field names, wrong enum values — is a **hard runtime error** that kills the stream.

### Before implementing or modifying any SSE chunk type

1. Read the Zod schema in `node_modules/ai/src/ui-message-stream/ui-message-chunks.ts`
2. Match the **exact** field set — no additions, no omissions
3. Verify field names match `camelCase` keys exactly (e.g. `approvalId` not `approval_id`)
4. Check string enum values use hyphens (e.g. `"tool-calls"` not `"tool_calls"`)
5. Add a test in `test/ai_core/test_ui_message_chunk.ml` asserting exact JSON output
6. Check how the chunk is processed in `node_modules/ai/src/ui/process-ui-message-stream.ts`

## Two Conversion Paths That Must Stay In Sync

- **Server → Client:** `stream_text` → `stream_text_result.to_ui_message_stream` → SSE chunks (must match `ui-message-chunks.ts`)
- **Client → Server:** request body → `server_handler.parse_messages_from_body` (must match `convert-to-model-messages.ts`)

A change to one often requires a change to the other.

## Frontend Re-submission Format Differs From Server Emission

When the frontend re-sends messages (e.g. after tool approval), the JSON shape differs:

- **No `toolName` field** — tool name is in the type prefix (`tool-get_weather` → `get_weather`)
- **Nested fields** — e.g. `approved` is inside `approval.approved`, not top-level
- **Multiple steps in one message** — separated by `step-start` parts, not separate messages

Our `parse_messages_from_body` splits assistant messages at `step-start` boundaries and uses `resolve_tool_name` / `resolve_approved` helpers. This matches upstream's `convertToModelMessages`.

## Read Upstream Source, Not Just Docs

The docs describe the API; the source describes the architecture. Before implementing a feature:

1. Read the upstream TypeScript implementation, not just the API docs
2. Trace the full path: frontend action → HTTP request → server parsing → LLM call → SSE response → frontend processing
3. Every boundary between these is a potential mismatch

## Upstream Dependency Management

The root `package.json` pins `ai` and `@ai-sdk/react` for upstream reference. All reference file reads use the **repo-root** `node_modules/`, not the example directories.

See `docs/upstream-deps-updated.md` for current versions, update procedure, and staleness policy.

## Key Upstream Reference Files

All paths relative to repo root.

| What | File |
|------|------|
| SSE chunk Zod schemas | `node_modules/ai/src/ui-message-stream/ui-message-chunks.ts` |
| Client chunk processing | `node_modules/ai/src/ui/process-ui-message-stream.ts` |
| UI → model message conversion | `node_modules/ai/src/ui/convert-to-model-messages.ts` |
| Tool approval collection | `node_modules/ai/src/generate-text/collect-tool-approvals.ts` |
| Stream text approval flow | `node_modules/ai/src/generate-text/stream-text.ts` |
| useChat hook | `node_modules/@ai-sdk/react/src/use-chat.ts` |
| Chat class internals | `node_modules/ai/src/ui/chat.ts` |

## Full Path Trace Checklist

Before committing a fix for any protocol issue, trace through all of these:

- [ ] Frontend action (click, submit) → what JS function fires?
- [ ] HTTP request body → what JSON does the frontend send?
- [ ] `parse_messages_from_body` → what `Prompt.message list` is produced?
- [ ] `collect_pending_tool_approvals` → are approvals detected correctly?
- [ ] `stream_text` / `generate_text` → initial step vs LLM step?
- [ ] Provider serialization → does the LLM API accept the message format?
- [ ] LLM response → SSE chunk emission → correct chunk type and fields?
- [ ] `to_ui_message_stream` → correct chunk sequence? (e.g. `tool-input-start` before `tool-output-available`)
- [ ] Frontend `processUIMessageStream` → does it accept the chunks without error?
