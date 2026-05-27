# OpenRouter Prompt Caching — Implementation Plan

**Status:** Implemented 2026-05-27
**Date:** 2026-05-26
**Owner:** ai_provider_openrouter

## 1. Goal

Bring `ai_provider_openrouter` to parity with `@openrouter/ai-sdk-provider@main` for prompt caching, covering both Anthropic automatic caching and per-content-block explicit breakpoints (Anthropic, Gemini, Alibaba Qwen, DeepSeek-v3.2). After this change, code that sets cache markers on `Prompt.user_part` / `Prompt.system` / `Prompt.assistant_part` / tool-result `provider_options` produces caching behavior consistent with the upstream TypeScript provider when routed through OpenRouter.

Out of scope: changes to Anthropic-native provider (already shipped in commit 175f99b); any new caching surface beyond what upstream already exposes; live integration testing.

## 2. Source-of-truth references

While implementing each step below we **re-read** the relevant upstream file before changing any related OCaml file. Do not implement from memory of this plan — verify the upstream behavior, then mirror.

- `https://raw.githubusercontent.com/OpenRouterTeam/ai-sdk-provider/main/src/chat/convert-to-openrouter-chat-messages.ts` — per-message/per-part cache control placement
- `https://raw.githubusercontent.com/OpenRouterTeam/ai-sdk-provider/main/src/chat/index.ts` — top-level `cache_control` merging from `settings.cache_control` and `providerOptions.openrouter.{cacheControl,cache_control}`; usage parsing
- `https://openrouter.ai/docs/features/prompt-caching` — model-family matrix, `cache_discount`, `ttl` values
- `https://openrouter.ai/docs/api-reference/chat-completion` — top-level `cache_control` JSON schema (`AnthropicCacheControlDirective`)

Read these before each step that touches cache logic. If upstream has changed since this plan was written, prefer upstream over this document and update the plan.

## 3. Current state (verified 2026-05-26)

- `Openrouter_options.cache_control : { type_: string; ttl: string option } option` — serialized as a **top-level body field** via `openrouter_model.ml:84,143` and `openrouter_api.ml:33,92`. ✅ Matches upstream `settings.cache_control` path.
- `lib/ai_provider_openrouter/convert_prompt.ml` is a single line: `include Ai_provider_openai.Convert_prompt`. The OpenAI converter ignores per-part `provider_options` entirely, so **no per-content-block `cache_control` is emitted** today. ❌ Gap.
- `convert_usage.ml` already parses `prompt_tokens_details.cached_tokens` and `cache_write_tokens` into `Openrouter_usage_metadata.{cache_read_tokens, cache_write_tokens}`. ✅ (Upstream only reads `cached_tokens`; we read both. Keep both.)
- `usage.cache_discount` (top-level under `usage`) is **not** parsed today. Upstream also does not parse it — it's a docs-only telemetry field. Decision deferred to step 7.
- `Cache_control_options.Cache` GADT key exists in `ai_provider_anthropic`. OpenRouter cannot import it directly (circular dep risk), so we introduce a parallel key + accept the Anthropic one as a fallback (mirroring upstream's `providerOptions.anthropic.cacheControl` compatibility).

## 4. Wire-format contract we must produce

These exact JSON shapes are the acceptance criteria for the converter. Cross-reference upstream `convert-to-openrouter-chat-messages.ts` line-by-line during implementation.

### 4.1 Top-level (already done)

```json
{ "model": "...", "messages": [...], "cache_control": { "type": "ephemeral", "ttl": "1h" } }
```

`ttl` is optional. Field is omitted entirely when not set. Only sent for Anthropic upstreams; OpenRouter strips it for Bedrock/Vertex routes (server-side).

### 4.2 System message — always wrapped in a single-text-part array

```json
{ "role": "system",
  "content": [ { "type": "text", "text": "...", "cache_control": { "type": "ephemeral" } } ] }
```

Note upstream **always** wraps `system` content as an array of one `text` part, even with no cache control. We must follow — this is observable to OpenRouter's request normalizer and divergence here would be a wire-format regression.

### 4.3 User — single text part

```json
// With cache control:
{ "role": "user",
  "content": [ { "type": "text", "text": "...", "cache_control": {...} } ] }

// Without:
{ "role": "user", "content": "..." }
```

When there is exactly one text part, the message-level cache control falls back to the part's cache control (`getCacheControl(providerOptions) ?? getCacheControl(content[0].providerOptions)`). The shape changes from `string` to a one-element array iff a cache control is set.

### 4.4 User — multi-part

```json
{ "role": "user",
  "content": [
    { "type": "text", "text": "...", "cache_control": {...} },
    { "type": "image_url", "image_url": { "url": "..." } }
  ] }
```

Per-part `cache_control` takes precedence over message-level. Message-level cache control falls through to the **last text part** only. Image/file/audio/video parts get cache control only when set explicitly on the part itself. **No root-level `cache_control` on multi-part user messages.** (Upstream comment line ~212: "For multi-part messages, don't add cache_control at the root level.")

### 4.5 Assistant — `cache_control` at root, not on content

```json
{ "role": "assistant",
  "content": "...",
  "tool_calls": [...],
  "cache_control": { "type": "ephemeral" } }
```

Read from message-level `provider_options`. Field omitted entirely when not set.

### 4.6 Tool — `cache_control` at root, fallback to per-result

```json
{ "role": "tool", "tool_call_id": "...", "content": "...", "name": "...",
  "cache_control": { "type": "ephemeral" } }
```

Source: `getCacheControl(providerOptions) ?? getCacheControl(toolResponse.providerOptions)` — message-level wins, falls through to per-tool-result `provider_options`. **Note**: our current `Prompt.Tool` message wraps a list of `tool_result`s; upstream emits one `role: tool` message per result. We already do this. Each emitted message gets the cache_control resolved against that specific tool_result.

### 4.7 Tool definitions

Upstream does **not** emit `cache_control` on tool definitions in the `tools` array, even though the OpenAPI schema permits it. We follow upstream: do not add `cache_control` to tool definitions.

### 4.8 Cache control value shape

```json
{ "type": "ephemeral" }
// or
{ "type": "ephemeral", "ttl": "5m" }  // or "1h"
```

The OpenRouter docs only document `type: "ephemeral"`. Upstream type is `{ type: 'ephemeral' }` (no `ttl`), but the runtime serialization is open — if a user puts `ttl` in via `extra_body`-style passthrough, it goes through. Our existing `Openrouter_options.cache_control` already has `ttl: string option`; keep that for the **per-part** type too, to allow `"1h"` breakpoints.

## 5. Module design

### 5.1 New: `Openrouter_cache_control` (`cache_control.ml` / `.mli`)

Mirrors `Ai_provider_anthropic.Cache_control` but lives in `ai_provider_openrouter`.

```ocaml
(* cache_control.mli *)
type breakpoint = Ephemeral
type ttl = Ttl_5m | Ttl_1h
type t = { cache_type : breakpoint; ttl : ttl option }

val ephemeral : t
val ephemeral_1h : t
val to_json : t -> Yojson.Basic.t      (* { "type": "ephemeral" [, "ttl": "1h"] } *)
val of_json : Yojson.Basic.t -> t      (* tolerant parser, used for tests *)
```

**Re-verify before implementing:** the JSON shape against `https://openrouter.ai/docs/features/prompt-caching` — section "Anthropic explicit caching" and "Gemini caching."

### 5.2 New: `Openrouter_cache_control_options` (`.ml` / `.mli`)

Mirrors `Anthropic_options.Cache_control_options`. Provides the per-part GADT key.

```ocaml
type _ Ai_provider.Provider_options.key +=
  | Cache : Cache_control.t Ai_provider.Provider_options.key

val with_cache_control :
  ?cache_control:Cache_control.t ->
  Ai_provider.Provider_options.t -> Ai_provider.Provider_options.t

val get_cache_control : Ai_provider.Provider_options.t -> Cache_control.t option
```

`get_cache_control` resolution mirrors upstream `getCacheControl()`:

1. Look up `Openrouter_cache_control_options.Cache` first.
2. Fall back to `Ai_provider_anthropic.Cache_control_options.Cache` (so that prompts written for Anthropic-native work unchanged through OpenRouter; this is upstream behavior).
3. **Rebuild the record at the boundary.** GADT keys are nominal — even when payloads are structurally identical, they remain distinct types. Convert by reconstructing the record field-by-field. If the two `t`s ever diverge, the compiler will flag the conversion site, which is what we want.

```ocaml
let get_cache_control po =
  match Ai_provider.Provider_options.find Cache po with
  | Some cc -> Some cc
  | None ->
    match Ai_provider.Provider_options.find
            Ai_provider_anthropic.Cache_control_options.Cache po with
    | Some (a : Ai_provider_anthropic.Cache_control.t) ->
      Some { Cache_control.cache_type = Ephemeral;
             ttl = (match a.ttl with
                    | Some Ttl_5m -> Some Ttl_5m
                    | Some Ttl_1h -> Some Ttl_1h
                    | None -> None) }
    | None -> None
```

**Dependency note:** This introduces a build-time dep from `ai_provider_openrouter` to `ai_provider_anthropic` purely for the GADT key. Verify the `dune` file does not create a cycle (Anthropic provider must not depend on OpenRouter). This is decided — the architectural awkwardness is accepted for the locality of the change.

### 5.3 Replace `convert_prompt.ml` (fork from OpenAI converter)

Stop `include Ai_provider_openai.Convert_prompt`. Write a full converter that mirrors `convert-to-openrouter-chat-messages.ts` structurally. We will not reuse OpenAI's converter because:

- We need per-part `cache_control` emission.
- The system-message wrapping rule (always array of one text part) diverges from OpenAI.
- The user-message single-vs-multi-part branching diverges.

Preserve everything else the OpenAI converter does today — file/image/audio handling, tool-call serialization, tool-result content shape — by copying the structure and adding the cache-control plumbing. The diff against OpenAI's converter is what reviewers should focus on.

**Function-by-function mapping vs upstream `convert-to-openrouter-chat-messages.ts`:**

| Upstream | Ours |
|---|---|
| `getCacheControl(providerOptions)` | `Openrouter_cache_control_options.get_cache_control` (with Anthropic fallback) |
| `case 'system'` | `System { content; provider_options } ->` emit single-element text-array, attach cache_control |
| `case 'user'` single text path | `User { content = [Text { text; provider_options = part_po }] }` with `cache_control = msg_po cc ?? part_po cc` |
| `case 'user'` multi-part path | iterate parts, resolve per-part cache (part cc ?? (is_last_text then msg cc else None)) |
| `case 'assistant'` | aggregate text + tool calls, emit `cache_control` at root |
| `case 'tool'` | emit one `role:tool` per result, `cache_control = msg cc ?? result cc` |

Cross-reference upstream during implementation. Do not rely on the table — it is a navigation aid, not the spec.

### 5.4 Adjust JSON record types in `convert_prompt.ml`

Need new records that include optional `cache_control` fields:

- `text_content_part_with_cache` — `{ type_; text; cache_control }`
- `image_url_content_part_with_cache` — same plus image
- `system_msg_array_json` — `{ role; content: text_content_part_with_cache list }`
- `assistant_msg_with_tools_json` and `assistant_msg_text_json` need `cache_control` added
- `tool_msg_json` needs `cache_control` and `name` added

Use `[@json.option] [@json.drop_default]` so omitted fields don't serialize. Verify with a unit test that the absence path produces byte-for-byte the same JSON we ship today (no caching → no diff).

### 5.5 No changes to `openrouter_api.ml`

The existing top-level `cache_control` field path is correct. Do not touch it.

### 5.6 No changes to `Openrouter_options.t`

`Openrouter_options.cache_control` stays as the typed top-level setting. We are **not** removing it — upstream keeps `settings.cache_control` AND `providerOptions.openrouter.cacheControl` AND `providerOptions.openrouter.cache_control` as three equivalent entry points. Our `Openrouter_options.cache_control` is the equivalent of `settings.cache_control`.

## 6. Usage parsing

Verify against upstream `src/chat/index.ts:483-520` and OpenRouter docs.

- `prompt_tokens_details.cached_tokens` → `Openrouter_usage_metadata.cache_read_tokens` ✅ (already done)
- `prompt_tokens_details.cache_write_tokens` → `Openrouter_usage_metadata.cache_write_tokens` ✅ (we have this; upstream does not, but it's documented in OpenRouter docs for Anthropic upstreams; keep)
- `usage.cache_discount` (top-level float) → **deferred.** Upstream does not surface it; no concrete consumer in our repo. Add when someone asks.

No code change in step 6.

## 7. Examples

New file: `examples/openrouter_prompt_caching.ml`.

Two runs against `anthropic/claude-3.5-sonnet` (or whichever model is cheapest with a 1024+ token cache threshold):

1. **Top-level mode**: set `Openrouter_options.cache_control = Some { type_ = "ephemeral"; ttl = Some "5m" }`. Send a large system prompt, two requests back-to-back. Print `cache_read_tokens` / `cache_write_tokens`.
2. **Explicit breakpoint mode**: leave top-level unset; pass `~system_provider_options` carrying `Openrouter_cache_control_options.Cache = Cache_control.ephemeral`. Same two requests. Print the same metrics.

Optionally a Gemini variant (`google/gemini-2.5-pro` or similar — verify a model that supports explicit breakpoints against the docs matrix) to prove non-Anthropic per-block caching works.

Register in `examples/dune`. Document `OPENROUTER_API_KEY` requirement at top of file.

## 8. Tests

### 8.1 Unit — `test/ai_provider_openrouter/test_convert_prompt.ml`

Add cases for each placement:

- system with cache_control → emits single-element array with `cache_control` on the text part
- user single text with cache_control → emits one-element content array
- user single text without cache_control → emits string (no shape change vs today)
- user multi-part: cache on second-to-last text part → only that part gets it
- user multi-part: cache only at message level → only last text part gets it
- assistant with text + tool calls + message-level cache → `cache_control` at root
- tool with message-level cache → `cache_control` on each emitted `role:tool`
- tool with per-result cache → same
- tool with both → message-level wins
- fallback: `Anthropic.Cache_control_options.Cache` set instead of OpenRouter key → still emitted
- no caching anywhere → assert JSON is byte-equivalent to current output (no regression)

Use `Yojson.Basic.to_string` comparisons. Snapshots optional.

### 8.2 Unit — `test/ai_provider_openrouter/test_openrouter_model.ml`

Add a top-level-cache test: `Openrouter_options.cache_control = Some {...}` → assert request body contains `"cache_control"`.

### 8.3 No live integration tests

OpenRouter live calls cost money and require an API key. The example covers the live path manually.

## 9. Documentation

Add a section to `docs/UPSTREAM_INTEROP.md`:

- The two cache-control modes (top-level Anthropic auto vs per-part explicit).
- The model-family matrix from the OpenRouter docs (which families need explicit, which are implicit).
- The "no separate OpenRouter cache" clarification — there is only provider sticky routing on top of the upstream provider's cache.
- The `Openrouter_cache_control_options.Cache` and `Openrouter_options.cache_control` entry points and when to use each.
- A pointer to upstream files we mirror.

## 10. Order of work

Each step is independently committable. Verify upstream files at the start of each step.

1. Add `Cache_control` module + `.mli` + JSON round-trip test.
2. Add `Cache_control_options` module + `.mli` (with Anthropic fallback) + key resolution unit test.
3. Fork `convert_prompt.ml` from OpenAI's, structurally mirror upstream `convert-to-openrouter-chat-messages.ts`. Keep behavior identical to today when no cache markers are set (assert via byte-equality test on a representative prompt).
4. Add `cache_control` plumbing to the new converter for each case (system, user single, user multi, assistant, tool). Add unit tests per case.
5. Update `dune` files for new modules (add `ai_provider_anthropic` dep on `ai_provider_openrouter`; verify no cycle).
6. Add the `openrouter_prompt_caching.ml` example and wire `examples/dune`.
7. Update `docs/UPSTREAM_INTEROP.md`.

## 11. Risk / non-obvious things

- **System message shape change.** Today we emit `{ role: "system", content: "..." }`. Upstream emits `{ role: "system", content: [{ type: "text", text: "..." }] }` **always**. This is a wire-format change for every request, even those not using caching. Confirm both shapes round-trip identically through OpenRouter (Chat Completions spec accepts both). Decision: change unconditionally, mirror upstream. Note this in the changelog.
- **Anthropic fallback dependency.** `ai_provider_openrouter` will build-depend on `ai_provider_anthropic` purely for the GADT key fallback. Verify no dune cycle exists (Anthropic must not depend on OpenRouter). Accepted trade-off.
- **`ttl` field on per-part cache.** OpenRouter docs explicitly mention `ttl` for Anthropic. Upstream TS type omits `ttl` from the per-part type but the runtime serialization is loose. We expose `ttl` because it works on the wire and matches our Anthropic-native module. Document as "supported on Anthropic upstreams, ignored elsewhere."
- **`Reasoning` part on assistant messages.** Upstream has elaborate reasoning-details deduplication + signature-stripping (`reasoning_details` array). We do not implement that today. Out of scope for this plan; flagged as separate work. Cache control on assistant messages is independent.
- **Strict-JSON-mode interaction.** Top-level `cache_control` is currently included in the body before any potential JSON-mode response_format manipulation. Verify in step 5 that no other field-ordering assumption breaks.
- **Provider sticky routing is server-side.** No client work. Just document it.

## 12. Out of scope

- `reasoning_details` round-tripping (separate issue).
- Tool definition cache_control (upstream doesn't do it; if we ever want this, file a separate plan).
- Streaming usage `cache_discount` (deferred with §6).
- Updating the playground UI to expose caching toggles.

## 13. Acceptance criteria

- All new unit tests pass.
- `dune build` succeeds.
- Manual run of `openrouter_prompt_caching.ml` shows non-zero `cache_read_tokens` on the second request (top-level mode) and on the second request of the explicit-breakpoint variant.
- For a prompt with **no** cache markers set anywhere, the serialized request body is byte-equivalent to the pre-change output, **except** for the system message which switches to the array shape — and that one diff is explicit in the test.
- `docs/UPSTREAM_INTEROP.md` has a "Prompt caching (OpenRouter)" section.

## Implementation log

- **Step 1 (cache_control module)**: Added `Cache_control` module mirroring `Ai_provider_anthropic.Cache_control` (sans `to_json_fields`), re-exported from the library, added Alcotest unit tests covering `to_json` and round-trip for `ephemeral`, `ephemeral_1h`, and explicit 5m. Upstream `convert-to-openrouter-chat-messages.ts` line 27 confirmed: `export type OpenRouterCacheControl = { type: 'ephemeral' };`; the `ttl` field is documented at https://openrouter.ai/docs/features/prompt-caching for Anthropic upstreams and is supported by the loose runtime serialization (see plan §4.8) — we expose it as planned. Files: `lib/ai_provider_openrouter/cache_control.{ml,mli}`, `lib/ai_provider_openrouter/ai_provider_openrouter.{ml,mli}`, `test/ai_provider_openrouter/test_cache_control.ml`, `test/ai_provider_openrouter/dune`. Deviations: none.
- **Step 2 (cache_control_options module)**: Added `Cache_control_options` GADT key with `with_cache_control` / `get_cache_control`, implementing the upstream `getCacheControl()` fallback chain (OpenRouter key → Anthropic key) by rebuilding the record field-by-field at the boundary. The plan's §5.2 snippet compiled as-is against current `Ai_provider_anthropic.Cache_control.{cache_type; ttl}` field names; no type drift. Added `ai_provider_anthropic` as a `(libraries ...)` dep in `lib/ai_provider_openrouter/dune` and confirmed no cycle (Anthropic's dune does not list openrouter). Re-exported from `ai_provider_openrouter.{ml,mli}`. Alcotest tests cover: openrouter key round-trip, fallback to Anthropic key, OpenRouter-wins-when-both-set, neither set returns `None`, and `Ttl_1h`/`Ttl_5m` preservation across the boundary. Files: `lib/ai_provider_openrouter/cache_control_options.{ml,mli}`, `lib/ai_provider_openrouter/dune`, `lib/ai_provider_openrouter/ai_provider_openrouter.{ml,mli}`, `test/ai_provider_openrouter/test_cache_control_options.ml`, `test/ai_provider_openrouter/dune`. Deviations: none.
- **Step 3 (fork convert_prompt)**: Replaced `include Ai_provider_openai.Convert_prompt` with a full fork. Re-read upstream `convert-to-openrouter-chat-messages.ts` (main branch, fetched fresh) and mirrored the switch-case structure for `system`, `user` (single-text and multi-part), `assistant`, and `tool`. New domain types are prefixed `or_*`/`openrouter_message`. JSON records use `[@json.option] [@json.drop_default]` on every `cache_control` field so the absence path remains byte-equivalent. Renamed the public serializer to `openrouter_message_to_json` and updated the lone caller in `lib/ai_provider_openrouter/openrouter_model.ml`. Files: `lib/ai_provider_openrouter/convert_prompt.{ml,mli}`, `lib/ai_provider_openrouter/openrouter_model.ml`, `test/ai_provider_openrouter/test_convert_prompt.ml`. Deviations: none.
- **Step 4 (per-part cache_control emission)**: Wired `Cache_control_options.get_cache_control` into each case of the new converter per plan §4.2–§4.6:
  - System: always array-of-one-text-part; `cache_control` attached to that text part when resolved on the message-level provider_options.
  - User single text: message-level CC wins, falls back to part-level; presence of either flips content from `string` to one-element array.
  - User multi-part: per-part CC wins; message-level CC falls through to the LAST text part only; non-text parts get only their own part-level CC; no root-level CC.
  - Assistant: root-level `cache_control` field threaded through the domain type (currently always `None` due to a Prompt API gap — see below).
  - Tool: one `role: tool` message per result; `cache_control = msg_cc ?? result_cc`; added the new `name` field.
  - Anthropic-key fallback verified via test (`test_system_with_anthropic_fallback`).
  - 14 new unit tests added (17 total in this suite, up from 2). Includes a byte-equivalence regression covering user single-text + assistant + tool (non-system, no caching).
  - **Deviation found and accepted (logged here, not silently fixed in code)**: the plan's test list assumes message-level cache control can be expressed on `Prompt.User`, `Prompt.Assistant`, and `Prompt.Tool`. Today only `Prompt.System` has a `provider_options` field (see `lib/ai_provider/prompt.mli` lines 70–77). The Anthropic provider has the same constraint and works around it the same way (per-part only, except system). The converter is written to accept message-level CC the moment those variants gain a `provider_options` field; the relevant tests (`user single text with msg-level cache_control`, `user single text with both → msg-level wins`, `assistant ... + msg-level cache`, `tool with msg-level cache`, `tool with both → msg-level wins`) cannot be exercised end-to-end and are therefore not included as unit tests. This does not affect the wire format for prompts written today, and the per-part path covers every realistic caching use-case currently expressible. A follow-up to broaden the Prompt API is out of scope for this plan.
  - Files: `lib/ai_provider_openrouter/convert_prompt.{ml,mli}`, `lib/ai_provider_openrouter/openrouter_model.ml`, `test/ai_provider_openrouter/test_convert_prompt.ml`.
- **Step 5 (dune)**: already-completed during step 2 (the `ai_provider_anthropic` build dep was added when the fallback key resolution landed); noted here for completeness. No further work required.
- **Step 6 (example)**: Added `examples/openrouter_prompt_caching.ml` demonstrating both cache-control modes against `anthropic/claude-3.5-sonnet`: (1) top-level via `Openrouter_options.cache_control = Some { type_ = "ephemeral"; ttl = Some "5m" }`, (2) explicit per-part via `~system_provider_options` carrying `Openrouter_cache_control_options.with_cache_control`. Two `generate_text` calls per mode; prints `input` / `output` / `cache_read_tokens` / `cache_write_tokens` extracted via `Ai_provider.Provider_options.find Convert_usage.Openrouter_usage`. Registered in `examples/dune` (added `openrouter_prompt_caching` to `names` and `ai_provider_openrouter` to `libraries`). Files: `examples/openrouter_prompt_caching.ml`, `examples/dune`. Deviations: none.
- **Step 7 (UPSTREAM_INTEROP + roadmap entry + mli gap docs)**: Added a new "Prompt caching (OpenRouter)" H2 section to `docs/UPSTREAM_INTEROP.md` covering the two cache-control modes, the model-family matrix from the OpenRouter docs, the no-separate-cache + sticky-routing clarification, the where-to-set-markers table, usage telemetry routing, the known gap on message-level `provider_options`, and the upstream-mirror file pointers. Documented the gap prominently in `lib/ai_provider_openrouter/cache_control_options.mli` under a "Supported placement today" / "Not yet supported" block that points at the v3 roadmap. Filed the gap as a new High-Priority entry in `docs/plans/2026-03-26-v3-roadmap.md` (item #5: "Message-level `provider_options` on User / Assistant / Tool prompts"); renumbered subsequent items #5–#16 → #6–#18. Files: `docs/UPSTREAM_INTEROP.md`, `lib/ai_provider_openrouter/cache_control_options.mli`, `docs/plans/2026-03-26-v3-roadmap.md`. Deviations: none.

## 14. Review checklist

When picking this plan up for implementation, before each module change:

- [ ] Re-read the corresponding upstream file from `OpenRouterTeam/ai-sdk-provider@main`. Note the commit SHA at the top of the implementation PR description.
- [ ] If upstream has diverged from §4, update §4 first, then implement.
- [ ] For every emitted field, find the producing line in the upstream TS file. If we cannot, do not emit it.
- [ ] For every test, write the upstream behavior we are asserting in a comment, with a link.
