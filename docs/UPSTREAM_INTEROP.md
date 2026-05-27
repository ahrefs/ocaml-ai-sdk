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

## Structured Outputs

`Mode.Object_json (Some schema)` from the `Output` API must map to each provider's
**native** structured-output API — never to prompt injection. The wire format is
different for every provider; never assume.

| Provider | Field | Shape |
|----------|-------|-------|
| OpenAI / OpenRouter | `response_format` | `{ type: "json_schema", json_schema: { name, schema, strict } }` |
| Anthropic (Haiku 4.5+, Sonnet 4.5+, Opus 4.5+) | `output_config` | `{ format: { type: "json_schema", schema } }` |
| Anthropic (older models) | `tools` + `tool_choice` | Synthetic `json` tool with schema as `input_schema`, forced `tool_choice = { type: "tool", name: "json" }` |

Anthropic's native field is GA as of 2025-11-13; no beta header is required.
When falling back to the synthetic tool, `Output.parse_output` reads the JSON
from the `"json"` tool call's `args`; `stream_text` feeds its
`tool-input-delta` stream into `Output.parse_partial`, giving streaming
callers identical behaviour to the native path. Keep these two paths in sync.

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

## Prompt caching (OpenRouter)

OpenRouter is a passthrough router. It does not cache responses itself —
the cache always lives on the upstream provider (Anthropic, Google,
Alibaba, DeepSeek). OpenRouter's value-add for caching is **provider
sticky routing**: a hash of `(first system message, first non-system
message)` keeps repeat requests on the same upstream provider so its
cache stays warm. See
[OpenRouter prompt caching docs](https://openrouter.ai/docs/features/prompt-caching).

### Two cache-control modes

**Top-level (Anthropic automatic).**
Set `Openrouter_options.cache_control = Some { type_ = "ephemeral"; ttl = Some "5m" }`
(or `"1h"`). Serialized as the request body's top-level `cache_control`
field. Only effective when OpenRouter routes to Anthropic directly;
OpenRouter strips it server-side for Bedrock and Vertex routes. Mirrors
upstream `settings.cache_control` /
`providerOptions.openrouter.cacheControl` /
`providerOptions.openrouter.cache_control` (all three are equivalent
upstream entry points; we expose the typed setting).

**Per-content-block (explicit breakpoints).**
Set `Openrouter_cache_control_options.Cache` (or, as fallback,
`Ai_provider_anthropic.Cache_control_options.Cache`) on individual
parts via their `provider_options`. Works on Anthropic explicit, Gemini
explicit, Alibaba Qwen, and DeepSeek-v3.2 upstreams.

### Model-family matrix

From the [OpenRouter docs](https://openrouter.ai/docs/features/prompt-caching):

| Family | Caching style | Marker required |
|---|---|---|
| OpenAI | Automatic | No |
| xAI Grok | Automatic | No |
| Moonshot | Automatic | No |
| Groq | Automatic | No |
| Gemini 2.5 (implicit) | Automatic | No |
| DeepSeek-V3 | Automatic | No |
| Anthropic Claude (explicit) | Per-block | Yes |
| Google Gemini (explicit) | Per-block | Yes |
| Alibaba Qwen | Per-block | Yes |
| DeepSeek-v3.2 | Per-block | Yes |

Top-level `cache_control` is only honored when routed to Anthropic
directly.

### Where to set markers

| Where you want to mark | OCaml call site |
|---|---|
| System message | `~system_provider_options` on `Generate_text.generate_text` / `Stream_text.stream_text` |
| User text or file part | `provider_options` on the `Prompt.Text` / `Prompt.File` user_part |
| Assistant text / file / reasoning / tool_call part | `provider_options` on that assistant_part |
| Tool result | `provider_options` on the `tool_result` record |

Per-part cache control takes precedence over message-level. Message-level
falls through to the **last text part only** for multi-part user
messages (mirrors upstream `convert-to-openrouter-chat-messages.ts`
~line 212).

### Known gap

Message-level `provider_options` on `Prompt.User`, `Prompt.Assistant`,
and `Prompt.Tool` is **not yet supported** — only `Prompt.System`
carries one. Upstream resolves `messagePO ?? partPO`, but the OCaml
`Prompt.message` type does not expose `provider_options` on the other
three variants. Workaround: set the cache marker on the specific part
or `tool_result` instead. Tracked in
`docs/plans/2026-03-26-v3-roadmap.md` under "Message-level
`provider_options` on User / Assistant / Tool prompts".

### Usage telemetry

OpenRouter responses surface cache metrics under
`usage.prompt_tokens_details`:

- `prompt_tokens_details.cached_tokens` →
  `Openrouter_usage_metadata.cache_read_tokens`
- `prompt_tokens_details.cache_write_tokens` →
  `Openrouter_usage_metadata.cache_write_tokens`

Stored in the `Convert_usage.Openrouter_usage` provider-metadata key.
Returned by both `Generate_text.generate_text` (on each step's
`provider_metadata`) and `Stream_text.stream_text` (on the
`provider_metadata` promise).

### Upstream mirroring

We mirror these files from
[OpenRouterTeam/ai-sdk-provider@main](https://github.com/OpenRouterTeam/ai-sdk-provider):

- `src/chat/convert-to-openrouter-chat-messages.ts` — per-part /
  per-message `cache_control` placement and the `getCacheControl()`
  fallback chain (OpenRouter key → Anthropic key).
- `src/chat/index.ts` — top-level `cache_control` merging from
  `settings.cache_control` and
  `providerOptions.openrouter.{cacheControl,cache_control}`; usage
  parsing.

If upstream diverges, prefer upstream and update this section.

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
