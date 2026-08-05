# Adaptive thinking + effort support (Anthropic provider)

**Status:** planned, not started
**Created:** 2026-08-03
**Revised:** 2026-08-04
**Ships as:** 3 stacked PRs, bottom targets main

## Goal

Add correct Anthropic request support for:

- manual thinking with budget tokens
- adaptive thinking
- explicit disabled thinking
- summarized or omitted thinking display
- output-config effort

The feature is complete only when thinking blocks and their signatures survive
non-streaming calls, streaming calls, server-side tool loops, and UI message
resubmission. Request serialization without signature continuity is not enough:
omitted thinking contains an empty text field and relies on its signature for
multi-turn continuity.

## Current limitations

The public thinking type models only the legacy manual shape:

    type t = {
      enabled : bool;
      budget_tokens : budget_tokens;
    }

Anthropic_api therefore emits only:

    { "thinking": { "type": "enabled", "budget_tokens": 4096 } }

This request is rejected by adaptive-only models, deprecated on Opus 4.6 and
Sonnet 4.6, and still required by older manual-thinking models. The provider
cannot currently emit adaptive or explicit disabled thinking, cannot set
display, and has no public path for output_config.effort.

The response path also loses thinking continuity:

- Convert_stream ignores signature_delta events.
- Prompt_builder discards signatures from non-streaming reasoning content.
- The streaming tool loop omits reasoning blocks when constructing the next
  assistant message.
- Convert_prompt emits an empty signature when no real signature is available.
- UI reasoning chunks omit providerMetadata, and Server_handler does not read
  providerMetadata from reasoning parts.

These gaps already affect manual thinking and become more visible with adaptive
thinking, especially when display is omitted.

## Upstream authority

Checked 2026-08-04:

- [Thinking](https://platform.claude.com/docs/en/build-with-claude/thinking)
- [Adaptive thinking](https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking)
- [Effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- [Model migration guide](https://platform.claude.com/docs/en/about-claude/models/migration-guide)
- [Messages API reference](https://platform.claude.com/docs/en/api/messages)
- [Official Python enabled-thinking type](https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/thinking_config_enabled_param.py)
- [Vercel Anthropic provider](https://github.com/vercel/ai/blob/main/packages/anthropic/src/anthropic-language-model.ts)
- [Vercel Anthropic prompt conversion](https://github.com/vercel/ai/blob/main/packages/anthropic/src/convert-to-anthropic-prompt.ts)
- [Vercel UI stream processing](https://github.com/vercel/ai/blob/main/packages/ai/src/ui/process-ui-message-stream.ts)
- [Vercel UI-to-model conversion](https://github.com/vercel/ai/blob/main/packages/ai/src/ui/convert-to-model-messages.ts)

Anthropic documentation and generated official SDK types are authoritative for
the API wire contract. Vercel source is the architectural reference for
provider metadata, streaming, and UI resubmission.

The root node_modules snapshot is reference-only and was stale when this plan
was revised. Before implementation, refresh it according to
docs/upstream-deps-updated.md and record the resulting versions. Do not use
old provider-options documentation to override current Anthropic API docs.

## Current capability matrix

Display is valid on both manual and adaptive thinking. The default shown below
applies when thinking is active and display is omitted.

| Model ID | Omit thinking | Adaptive | Manual enabled | Explicit disabled | Display default | Effort |
|---|---|---|---|---|---|---|
| claude-fable-5 | adaptive, always on | yes | no | no | omitted | low, medium, high, xhigh, max |
| claude-mythos-5 | adaptive, always on | yes | no | no | omitted | low, medium, high, xhigh, max |
| claude-mythos-preview | adaptive, on | yes | yes | no | omitted | low, medium, high, max |
| claude-opus-5 | adaptive, on | yes | no | high or below only | omitted | low, medium, high, xhigh, max |
| claude-opus-4-8 | off | yes | no | yes | omitted | low, medium, high, xhigh, max |
| claude-opus-4-7 | off | yes | no | yes | omitted | low, medium, high, xhigh, max |
| claude-opus-4-6 | off | yes | deprecated, accepted | yes | summarized | low, medium, high, max |
| claude-sonnet-5 | adaptive, on | yes | no | yes | omitted | low, medium, high, xhigh, max |
| claude-sonnet-4-6 | off | yes | deprecated, accepted | yes | summarized | low, medium, high, max |
| claude-opus-4-5 | off | no | yes | yes | summarized | low, medium, high |
| claude-sonnet-4-5 | off | no | yes | yes | summarized | none |
| claude-haiku-4-5 | off | no | yes | yes | summarized | none |

Older models that support thinking use manual enabled thinking with a budget.
Unknown or custom model IDs must remain pass-through because the provider also
supports Anthropic-compatible endpoints.

## Wire semantics

Thinking.t option has two distinct layers of meaning:

| OCaml value | Wire value |
|---|---|
| None | omit the thinking key |
| Some Disabled | thinking.type = disabled |
| Some Adaptive | thinking.type = adaptive |
| Some Enabled | thinking.type = enabled with budget_tokens |

Omission must not be used to represent Disabled. On Sonnet 5 and Opus 5,
omission leaves adaptive thinking enabled. Models that cannot disable thinking
must be rejected by model-aware validation.

Required thinking shapes:

    { "thinking": { "type": "disabled" } }
    { "thinking": { "type": "adaptive" } }
    { "thinking": { "type": "adaptive", "display": "summarized" } }
    { "thinking": { "type": "adaptive", "display": "omitted" } }
    { "thinking": { "type": "enabled", "budget_tokens": 4096 } }
    { "thinking": {
        "type": "enabled",
        "budget_tokens": 4096,
        "display": "omitted"
      } }

Effort is independent of thinking and lives beside structured output format:

    { "output_config": { "effort": "high" } }
    { "output_config": {
        "format": { "type": "json_schema", "schema": {} },
        "effort": "xhigh"
      } }

Do not emit an empty output_config object.

## Target public API

### Thinking

    type budget_tokens = private int

    val budget : int -> (budget_tokens, string) result
    val budget_exn : int -> budget_tokens
    val to_int : budget_tokens -> int

    type display =
      | Summarized
      | Omitted

    type t =
      | Enabled of {
          budget_tokens : budget_tokens;
          display : display option;
        }
      | Adaptive of { display : display option }
      | Disabled

Keep the existing minimum budget validation. Cross-field validation against
max_tokens remains out of scope because manual interleaved-thinking rules have
model-specific exceptions.

### Effort

    type t =
      | Low
      | Medium
      | High
      | Xhigh
      | Max

    val to_string : t -> string

Re-export Effort from Ai_provider_anthropic.

### Provider options

    type t = {
      thinking : Thinking.t option;
      effort : Effort.t option;
      tool_streaming : bool;
      structured_output_mode : structured_output_mode;
    }

The default remains no explicit thinking configuration and no explicit effort.

### Model capabilities

Do not replace supports_thinking with a three-case enum: Opus 4.6 and Sonnet
4.6 support both manual and adaptive thinking, so that representation is
lossy. Model the independent dimensions:

    type disabled_thinking_support =
      | Allowed
      | Up_to_high
      | Unsupported

    type thinking_capabilities = {
      manual : bool;
      adaptive : bool;
      defaults_to_adaptive : bool;
      disabled : disabled_thinking_support;
      effort_levels : Effort.t list;
      display_default : Thinking.display option;
    }

    type model_capabilities = {
      thinking : thinking_capabilities option;
      rejects_sampling_parameters : bool;
      (* existing capability fields *)
    }

For Custom models, thinking = None means unknown, not unsupported. Skip
model-specific rejection and preserve caller-supplied fields.

## Request policy

Apply policy before constructing or sending the HTTP request.

- Reject known model/mode combinations that the API guarantees will reject.
  There is no faithful automatic conversion from a manual token budget to an
  adaptive effort level.
- Reject unsupported explicit effort levels on known models.
- Reject Disabled on Fable 5, Mythos 5, and Mythos Preview.
- For Opus 5 with Disabled plus Xhigh or Max, lower effort to High and emit an
  unsupported-feature warning, matching current upstream provider behavior.
- Remove incompatible temperature, top_p, and top_k fields before
  serialization and emit warnings. Account for models that reject sampling
  parameters regardless of whether thinking was explicitly configured.
- Reject forced tool choice with manual Enabled thinking. Adaptive thinking
  supports forced tool choice.
- Do not add model-based failures for Custom IDs.

A warning without normalization is insufficient: provider warnings are only
observable after a successful request, while a 400 fails before they can be
returned.

Adaptive thinking automatically enables interleaved thinking and needs no
interleaved-thinking beta header. Preserve the existing header only for manual
Enabled mode; Disabled, Adaptive, and omission add no thinking beta.

## PR 1 — Preserve thinking signatures end to end

Fix the existing continuity bug before adding a mode that commonly hides
thinking text.

### Provider response and prompt conversion

- Parse signature_delta in Convert_stream. Treat the event value as the
  current complete signature, as the official SDK does.
- Attach Anthropic signature metadata to reasoning content in both streaming
  and non-streaming paths.
- Preserve reasoning provider options in Prompt_builder instead of replacing
  them with empty options.
- Include reasoning content when the streaming tool loop constructs the
  assistant message for the next step.
- Convert_prompt must serialize the original thinking text and signature
  unchanged. Never synthesize an empty signature; fail locally if a caller
  attempts to forward an Anthropic thinking block without its signature.

### Core and UI propagation

- Carry reasoning provider metadata through Text_stream_part and
  Ui_message_chunk reasoning start, delta, and end events.
- Emit providerMetadata.anthropic.signature on the reasoning event that
  receives signature_delta.
- Parse the generic providerMetadata field on UI reasoning parts in
  Server_handler and restore it to Prompt.Reasoning.provider_options.
- Preserve existing tool call and tool result metadata behavior.

### Tests

Add the smallest fixtures that prove:

1. A non-streaming thinking plus tool-use response is echoed into the next
   request with the original thinking text and signature.
2. A streamed thinking_delta plus signature_delta plus tool-use response is
   echoed into the next request unchanged.
3. Omitted thinking, represented by empty text plus a signature, survives the
   same streamed round trip.
4. UI reasoning provider metadata survives server emission, frontend-shaped
   resubmission, and Server_handler parsing.
5. Missing Anthropic reasoning signatures never produce signature = "".

Likely files:

- lib/ai_provider_anthropic/convert_response.ml
- lib/ai_provider_anthropic/convert_stream.ml
- lib/ai_provider_anthropic/convert_prompt.ml
- lib/ai_core/prompt_builder.ml
- lib/ai_core/stream_text.ml
- lib/ai_core/text_stream_part.ml and .mli
- lib/ai_core/ui_message_chunk.ml and .mli
- lib/ai_core/stream_text_result.ml
- lib/ai_core/server_handler.ml
- focused tests under test/ai_provider_anthropic and test/ai_core

## PR 2 — Atomic request API and wire support

The breaking Thinking type change and all its consumers belong in one PR so
the stack remains buildable.

### Public types and options

- Replace the old Thinking record with the target variant.
- Add Effort.ml and Effort.mli with to_string.
- Add effort to Anthropic_options.t and its default.
- Re-export Effort from Ai_provider_anthropic.ml and .mli.
- Update every in-repo Thinking constructor and match, including tests and
  examples.

### Request construction

- Serialize None and Disabled differently.
- Support display on both Enabled and Adaptive.
- Make output_config.format and output_config.effort optional siblings.
- Build one output_config value in Anthropic_model so effort-only,
  format-only, and combined requests use the same path.
- Omit output_config when both fields are absent.
- Make Beta_headers mode-aware: only manual Enabled requests add the
  interleaved-thinking header.
- Keep serialization independent from model validation; PR 3 supplies the
  known-model policy.

### Exact wire tests

Compare complete Yojson values rather than decoding with allow_extra_fields.
Cover:

- omitted thinking
- explicit disabled thinking
- adaptive with no display
- adaptive with each display value
- enabled with no display
- enabled with each display value
- effort-only output_config
- format-only output_config
- combined format and effort
- omission of empty output_config
- the full Anthropic_options to Anthropic_model to captured HTTP body path

Likely files:

- lib/ai_provider_anthropic/thinking.ml and .mli
- lib/ai_provider_anthropic/effort.ml and .mli
- lib/ai_provider_anthropic/anthropic_options.ml and .mli
- lib/ai_provider_anthropic/anthropic_api.ml and .mli
- lib/ai_provider_anthropic/anthropic_model.ml
- lib/ai_provider_anthropic/beta_headers.ml and .mli
- lib/ai_provider_anthropic/ai_provider_anthropic.ml and .mli
- test/ai_provider_anthropic/test_api.ml
- test/ai_provider_anthropic/test_anthropic_types.ml
- test/ai_provider_anthropic/test_anthropic_model.ml
- existing in-repo examples and E2E callsites

## PR 3 — Catalog, request policy, and examples

### Catalog

- Add Claude_fable_5, Claude_mythos_5, Claude_mythos_preview,
  Claude_opus_5, Claude_opus_4_8, and Claude_sonnet_5.
- Replace the coarse thinking boolean with the orthogonal thinking
  capabilities above.
- Add rejects_sampling_parameters.
- Audit every existing capability field for each new model rather than
  inheriting an unrelated base record.
- Correct stale existing data encountered during that audit, including Sonnet
  4.6 maximum output tokens.
- Keep Custom pass-through and conservative default max tokens.

Mythos 5 is limited availability, but it is an official API model and belongs
in a catalog that claims to enumerate current Anthropic models.

### Request policy

- Centralize known-model validation and normalization in Model_catalog and
  Anthropic_model; do not scatter string comparisons across serializers.
- Evaluate effective thinking defaults, so omitted thinking on Opus 5, Sonnet
  5, Fable 5, and Mythos models is treated as active where relevant.
- Normalize incompatible sampling parameters before calling
  Anthropic_api.make_request_body.
- Ensure emitted warnings describe the field actually removed or changed.
- Add table-driven tests for every row in the capability matrix and focused
  tests for invalid combinations.

### Examples and documentation

- Change examples/thinking.ml to adaptive thinking with explicit summarized
  display and effort.
- Update the AI E2E reasoning endpoint the same way.
- Document None versus Disabled and the omitted-display signature requirement.
- Do not make examples select unsupported modes merely to demonstrate every
  constructor; wire tests cover those shapes.

Likely files:

- lib/ai_provider_anthropic/model_catalog.ml and .mli
- lib/ai_provider_anthropic/anthropic_model.ml
- test/ai_provider_anthropic/test_config_catalog.ml
- test/ai_provider_anthropic/test_anthropic_model.ml
- examples/thinking.ml
- examples/ai-e2e/server/main.ml
- README or provider-facing documentation where thinking options are shown

## Verification

Per PR:

    dune build @all
    dune test

PR 1 additionally verifies exact thinking-block round trips through
non-streaming, streaming, tool-loop, and UI paths.

PR 2 verifies exact request JSON and the full provider-options request path.

PR 3 verifies the full model matrix, validation, normalization, warnings, and
all examples.

Live API probes are optional and require explicit credentials. Unit and mock
HTTP tests must be sufficient to verify the committed behavior.

## Out of scope

- Other providers' model catalogs.
- output_config.task_budget, speed, and fallbacks.
- Dynamic capability discovery through the Models API.
- Cross-field budget_tokens versus max_tokens validation.
- Redacted-thinking block support beyond preserving existing behavior.
- Cross-model fallback logic that strips old thinking blocks.
- A compatibility shim for the old Thinking record.

## Accepted breaking changes

- Thinking.t changes from a record to a variant.
- Anthropic_options.t gains effort.
- Model capabilities replace supports_thinking with structured thinking
  capabilities.

All in-repo consumers migrate in the same PR as each breaking type change. No
stacked PR may leave the repository or examples uncompilable.
