# Upstream Dependency Bump Analysis

**Date:** 2026-04-08
**Bumped from:** `ai@6.0.116` / `@ai-sdk/react@3.0.118`
**Bumped to:** `ai@6.0.153` / `@ai-sdk/react@3.0.155`
**Versions spanned:** 37 patch releases (lockstep releases from `vercel/ai` monorepo)

---

## 1. Release Notes Summary (6.0.117 → 6.0.153)

### Wire-Format Relevant

| Version | Change | Impact |
|---------|--------|--------|
| **6.0.120** | `feat(ai): pass result provider metadata across the stream` | **HIGH** — `providerMetadata` now emitted on `tool-output-available` and `tool-output-error` SSE chunks. Our OCaml types don't include this field. Since it's optional and `z.strictObject()` is used, we won't break by omitting it — but we should emit it when available for full parity. |
| **6.0.150** | `fix(ai): skip stringifying text when streaming partial text` | LOW — performance optimization in `stream-text.ts` for string partial output comparison. No wire-format change. |
| **6.0.119** | `feat(ai): add missing usage attributes` + `fix(ai): doStream should reflect transformed values` | LOW — telemetry attribute changes (`inputTokenDetails`, `outputTokenDetails` substructure). Internal to upstream's OpenTelemetry spans. |
| **6.0.117** | `chore(ai): add optional ChatRequestOptions to addToolApprovalResponse and addToolOutput` | MEDIUM — `addToolOutput` and `addToolApprovalResponse` now accept an optional `options` parameter forwarded when auto-sending. Server-side parsing is unaffected (extra fields in request body are ignored). |

### Non-Wire-Format (Informational)

| Version | Change | Impact |
|---------|--------|--------|
| 6.0.153 | `feat: support plain string model IDs in rerank()` | None for us. |
| 6.0.142 | `feat: add new isLoopFinished stop condition helper` | None — upstream helper, not wire format. |
| 6.0.135 | `chore: remove all experimental agent events` | LOW — removed experimental telemetry events we never implemented. |
| 6.0.134 | `chore: remove all experimental embed events` | LOW — same, embed events. |
| 6.0.131 | `feat: introduce experimental callbacks for embed function` | None for us. |
| 6.0.126 | `Remove custom User-Agent header from HttpChatTransport` | None — CORS fix, client-side only. |
| 6.0.118 | `fix(security): validate redirect targets in download functions (SSRF)` | None — client-side download security. |
| 6.0.144 | `fix: allow inline data URLs in download validation` | None — client-side. |
| 6.0.* (many) | `@ai-sdk/gateway` dependency bumps | None — internal gateway provider updates. |

---

## 2. File-by-File Diff Analysis

### `ui-message-chunks.ts` (Zod schemas) — CRITICAL

**Change:** `providerMetadata` field added to `tool-output-available` and `tool-output-error` chunk schemas.

```diff
+  providerMetadata: providerMetadataSchema.optional(),  // on tool-output-available
+  providerMetadata: providerMetadataSchema.optional(),  // on tool-output-error
```

**Impact on our OCaml code:**

Our `Ui_message_chunk.tool_output_available_json` and `tool_output_error_json` types do not include `providerMetadata`. Since the field is **optional** and these are server→client emissions, **omitting it is safe** (the Zod `.optional()` means `undefined` is valid). However, for full upstream parity, we should add it when we have provider metadata to forward.

**Action needed:** Future work — add optional `provider_metadata` to `Tool_output_available` and `Tool_output_error` variants in `ui_message_chunk.ml`. Not a breaking issue today.

### `process-ui-message-stream.ts` (Client processing) — MEDIUM

**Change:** When processing `tool-output-available` / `tool-output-error` chunks, the client now routes `providerMetadata` to either `callProviderMetadata` or `resultProviderMetadata` depending on the tool part's state:

- State `output-available` or `output-error` → stored as `resultProviderMetadata`
- Other states → stored as `callProviderMetadata`

Also, `providerMetadata` is now forwarded from `tool-input-start` and `tool-input-available` chunks.

**Impact on our code:** This is client-side processing logic. Our server just needs to emit valid chunks. The routing between `callProviderMetadata` and `resultProviderMetadata` happens entirely in the frontend. No action needed on our side.

### `convert-to-model-messages.ts` (Client→Server) — LOW

**Change:** When converting UI messages back to model messages (e.g., for re-submission after tool output), the client now prefers `resultProviderMetadata` over `callProviderMetadata`:

```typescript
const resultProviderMetadata = part.resultProviderMetadata ?? part.callProviderMetadata;
```

**Impact on our code:** This affects the JSON shape of re-submitted messages from the frontend. Our `parse_messages_from_body` would encounter a `resultProviderMetadata` field in tool result parts. Since we currently don't parse `providerMetadata` from incoming messages, this is a **no-op for now**. If/when we start forwarding provider metadata from client→server, we'll need to handle both field names.

### `chat.ts` (Chat class) — LOW

**Changes:**
1. `addToolApprovalResponse` now accepts optional `options: ChatRequestOptions` and forwards them
2. `addToolOutput` refactored: extracted `ChatAddToolOutputFunction` type, added `options` parameter
3. Both auto-send paths now spread `...options` into the request

**Impact on our code:** Server-side only impact would be receiving extra fields in the request body from newer clients. Since we parse with known keys and ignore extras, this is safe. No action needed.

### `use-chat.ts` (React hook) — NONE

**No changes.** The hook source is identical between versions.

### `collect-tool-approvals.ts` — NONE

**No changes.** Tool approval collection logic is identical.

### `stream-text.ts` — MEDIUM (for awareness)

**Changes:**
1. **Tool output emission now includes `providerMetadata`** — both `tool-output-available` and `tool-output-error` chunks can carry `providerMetadata` from the tool execution result
2. **Tool error text handling changed** — when `providerExecuted` is true, error text is now taken directly from `part.error` (stringified if needed) rather than going through `onError()`. This means provider-executed tool errors preserve the original error string.
3. **Telemetry restructured** — usage attributes moved from flat `reasoningTokens`/`cachedInputTokens` to nested `inputTokenDetails.noCacheTokens`, `inputTokenDetails.cacheReadTokens`, etc.
4. **Telemetry timing fix** — `doStreamSpan` attributes that depend on transforms (response text, reasoning) are now set AFTER the step is fully processed, with `doStreamSpan.end()` moved to a finally block after attribute setting.
5. **Partial text streaming optimization** — string partials now compared directly instead of JSON.stringify for better performance.

**Impact on our code:** Point (1) aligns with the `ui-message-chunks.ts` change above. Point (2) is upstream-internal error formatting. Points (3-5) are internal optimizations with no wire-format impact.

---

## 3. OCaml Code Impact Assessment

### No Breaking Changes

All upstream changes to the SSE wire format are **additive optional fields**. The `z.strictObject()` schemas with `.optional()` mean our current emissions remain valid. The frontend will simply see `undefined` for fields we don't emit.

### Recommended Future Work

See v2 roadmap items #16 (forward `providerMetadata` on tool output chunks) and #17 (parse `resultProviderMetadata` from re-submissions) for scoped work items created from this analysis.

Token detail telemetry restructuring (flat → nested `inputTokenDetails`/`outputTokenDetails`) is noted in v2 roadmap item #7 (Telemetry).

### No Action Required Now

Our current implementation is wire-format compatible. The upstream changes are backward-compatible additions. The critical `z.strictObject()` schemas accept our output as-is.

---

## 4. Dependency Versions After Bump

Repo-root `package.json` now tracks upstream deps (pinned to `latest`). Reference files are read from repo-root `node_modules/`, not example directories.

| Location | `ai` | `@ai-sdk/react` |
|----------|------|-----------------|
| Repo root | 6.0.154 | 3.0.156 |

Example directories were also bumped during the initial analysis (6.0.153 / 3.0.155) but are no longer the canonical reference source.

---

## 5. Recommendation

**Keep the bump.** There are zero breaking changes. The main benefit is that reference files now reflect current upstream, so future development work matches the latest wire format rather than a stale snapshot.

Going forward, deps are updated manually when stale (>15 days). See `docs/UPSTREAM_INTEROP.md` and `docs/upstream-deps-updated.md` for the procedure and tracking.
