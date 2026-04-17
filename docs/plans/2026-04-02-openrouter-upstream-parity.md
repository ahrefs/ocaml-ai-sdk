# OpenRouter Upstream Parity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all wire-behavior divergences between the OCaml OpenRouter provider and the upstream TypeScript `@openrouter/ai-sdk-provider` so they produce identical HTTP requests, parse identical responses, and handle errors identically.

**Architecture:** The upstream TypeScript provider is a thin wrapper over the OpenRouter API (which is itself OpenAI-compatible). It does NOT have a model catalog — all parameters are forwarded as-is. The provider passes OpenRouter-specific settings (`plugins`, `provider`, `reasoning`, `cache_control`, etc.) directly as top-level request body fields, and sends BYOK API keys via the `X-Provider-API-Keys` header. Response parsing handles `reasoning_details` (typed array with text/encrypted/summary variants) and nested usage structures (`prompt_tokens_details.cached_tokens`, `completion_tokens_details.reasoning_tokens`).

**Tech Stack:** OCaml, melange-json-native (PPX JSON derivers), Lwt, Alcotest, Cohttp

**Upstream reference:** https://github.com/OpenRouterTeam/ai-sdk-provider (main branch)

---

## Guiding Principles

1. **Delete inventions** — the model catalog, `[retryable]` prefix, `transforms`, `route` field, error type classification are all invented. Remove them.
2. **Match upstream wire format exactly** — nested JSON structures for usage, `reasoning_details` array, `X-Provider-API-Keys` header, `X-OpenRouter-Title` header.
3. **Don't invent defaults** — upstream sends `undefined` (omit) for unset fields; never inject `default_max_tokens`.
4. **Forward everything** — upstream merges `extraBody` and `providerOptions.openrouter` into the request body. We need an equivalent.

---

### Task 1: Fix `convert_usage.ml` — Match upstream nested JSON structure

The upstream API returns usage with nested objects:
```json
{
  "prompt_tokens": 100,
  "completion_tokens": 50,
  "prompt_tokens_details": { "cached_tokens": 80 },
  "completion_tokens_details": { "reasoning_tokens": 10 },
  "cost": 0.005,
  "cost_details": { "upstream_inference_cost": 0.004 }
}
```

The current OCaml type has flat fields (`cache_read_tokens`, etc.) that won't match the wire format.

**Files:**
- Modify: `lib/ai_provider_openrouter/convert_usage.ml`
- Modify: `lib/ai_provider_openrouter/convert_usage.mli` (if exists, otherwise the .ml is the interface)
- Test: `test/ai_provider_openrouter/test_convert_usage.ml`

**Step 1: Update the usage JSON type to match upstream nested structure**

Replace the flat `openrouter_usage` type with nested types matching the actual API wire format:

```ocaml
(* convert_usage.ml *)
open Melange_json.Primitives

type prompt_tokens_details = {
  cached_tokens : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type completion_tokens_details = {
  reasoning_tokens : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type cost_details = {
  upstream_inference_cost : float option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type openrouter_usage = {
  prompt_tokens : int option; [@json.default None]
  completion_tokens : int option; [@json.default None]
  total_tokens : int option; [@json.default None]
  prompt_tokens_details : prompt_tokens_details option; [@json.default None]
  completion_tokens_details : completion_tokens_details option; [@json.default None]
  cost : float option; [@json.default None]
  cost_details : cost_details option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type openrouter_usage_metadata = {
  cache_read_tokens : int;
  reasoning_tokens : int;
  cost : float option;
  upstream_inference_cost : float option;
}

type _ Ai_provider.Provider_options.key +=
  | Openrouter_usage : openrouter_usage_metadata Ai_provider.Provider_options.key

let to_usage u =
  let input = Option.value ~default:0 u.prompt_tokens in
  let output = Option.value ~default:0 u.completion_tokens in
  {
    Ai_provider.Usage.input_tokens = input;
    output_tokens = output;
    total_tokens = Some (Option.value ~default:(input + output) u.total_tokens);
  }

let to_metadata (u : openrouter_usage) =
  {
    cache_read_tokens =
      (match u.prompt_tokens_details with
      | Some d -> Option.value ~default:0 d.cached_tokens
      | None -> 0);
    reasoning_tokens =
      (match u.completion_tokens_details with
      | Some d -> Option.value ~default:0 d.reasoning_tokens
      | None -> 0);
    cost = u.cost;
    upstream_inference_cost =
      (match u.cost_details with
      | Some d -> d.upstream_inference_cost
      | None -> None);
  }
```

Note: Removed `cache_write_tokens` from metadata — upstream doesn't expose `cache_write_tokens` in its OpenRouter usage accounting type (it's in the V3 SDK usage but not in the provider metadata).

**Step 2: Update tests to use upstream-format JSON**

```ocaml
(* test_convert_usage.ml *)
open Alcotest

let test_basic_usage () =
  let json =
    Yojson.Basic.from_string {|{"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150}|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let sdk_usage = Ai_provider_openrouter.Convert_usage.to_usage usage in
  (check int) "input_tokens" 100 sdk_usage.input_tokens;
  (check int) "output_tokens" 50 sdk_usage.output_tokens;
  (check (option int)) "total_tokens" (Some 150) sdk_usage.total_tokens

let test_usage_with_nested_details () =
  let json =
    Yojson.Basic.from_string
      {|{
        "prompt_tokens": 200,
        "completion_tokens": 100,
        "total_tokens": 300,
        "prompt_tokens_details": { "cached_tokens": 150 },
        "completion_tokens_details": { "reasoning_tokens": 30 },
        "cost": 0.005,
        "cost_details": { "upstream_inference_cost": 0.004 }
      }|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let metadata = Ai_provider_openrouter.Convert_usage.to_metadata usage in
  (check int) "cache_read_tokens" 150 metadata.cache_read_tokens;
  (check int) "reasoning_tokens" 30 metadata.reasoning_tokens;
  (check (option float)) "cost" (Some 0.005) metadata.cost;
  (check (option float)) "upstream_inference_cost" (Some 0.004) metadata.upstream_inference_cost

let test_usage_missing_details () =
  let json =
    Yojson.Basic.from_string {|{"prompt_tokens": 10, "completion_tokens": 5}|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let metadata = Ai_provider_openrouter.Convert_usage.to_metadata usage in
  (check int) "cache_read_tokens defaults" 0 metadata.cache_read_tokens;
  (check int) "reasoning_tokens defaults" 0 metadata.reasoning_tokens;
  (check (option float)) "cost" None metadata.cost;
  (check (option float)) "upstream_inference_cost" None metadata.upstream_inference_cost

let test_usage_total_tokens_computed () =
  let json =
    Yojson.Basic.from_string {|{"prompt_tokens": 10, "completion_tokens": 5}|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let sdk_usage = Ai_provider_openrouter.Convert_usage.to_usage usage in
  (check (option int)) "total_tokens computed" (Some 15) sdk_usage.total_tokens

let () =
  run "Convert_usage"
    [
      ( "convert_usage",
        [
          test_case "basic_usage" `Quick test_basic_usage;
          test_case "nested_details" `Quick test_usage_with_nested_details;
          test_case "missing_details" `Quick test_usage_missing_details;
          test_case "total_tokens_computed" `Quick test_usage_total_tokens_computed;
        ] );
    ]
```

**Step 3: Run tests**

Run: `dune runtest test/ai_provider_openrouter 2>&1`
Expected: All tests pass (build may fail due to downstream references — fix in later tasks)

**Step 4: Commit**

```bash
git add lib/ai_provider_openrouter/convert_usage.ml test/ai_provider_openrouter/test_convert_usage.ml
git commit -m "fix(openrouter): match upstream nested usage JSON structure"
```

---

### Task 2: Fix `convert_response.ml` — Parse `reasoning_details` array and `provider` field

Upstream parses `choice.message.reasoning_details` (an array of `{type, text, signature, data, summary}` objects) and falls back to the legacy `reasoning` string. It also reads `response.provider` for routing metadata. It overrides finish reason when tool calls + encrypted reasoning are present.

**Files:**
- Modify: `lib/ai_provider_openrouter/convert_response.ml`
- Test: `test/ai_provider_openrouter/test_convert_response.ml`

**Step 1: Add reasoning_details types and update response parsing**

Add types for the three reasoning detail variants. Parse them from the response. Fall back to legacy `reasoning` string when `reasoning_details` is absent. Extract `provider` from response. Implement finish-reason overrides for encrypted reasoning + tool calls, and for `other` + tool calls.

The new `choice_message_json` should include:
```ocaml
type reasoning_detail_json = {
  type_ : string; [@json.key "type"] [@json.default ""]
  text : string option; [@json.default None]
  signature : string option; [@json.default None]
  data : string option; [@json.default None]
  summary : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]
```

And `choice_message_json` gains:
```ocaml
  reasoning_details : reasoning_detail_json list; [@json.default []]
```

And `openrouter_response_json` gains:
```ocaml
  provider : string option; [@json.default None]
```

The `parse_response` function should:
1. Parse `reasoning_details` first — map `reasoning.text` → `Reasoning { text; signature; ... }`, `reasoning.encrypted` → `Reasoning { text = "[REDACTED]"; ... }`, `reasoning.summary` → `Reasoning { text = summary; ... }`
2. Fall back to legacy `reasoning` string if `reasoning_details` is empty
3. Check if `has_tool_calls && has_encrypted_reasoning && finish_reason = "stop"` → override to `Tool_calls`
4. Check if `has_tool_calls && finish_reason = Other _` → override to `Tool_calls`
5. Store `provider` in provider_metadata

**Step 2: Update tests**

Add tests for:
- `reasoning_details` with text type (including signature)
- `reasoning_details` with encrypted type → `[REDACTED]`
- `reasoning_details` with summary type
- Legacy `reasoning` field fallback still works
- Finish reason override: tool_calls + encrypted reasoning + `stop` → `Tool_calls`
- Finish reason override: tool_calls + `other` → `Tool_calls`
- `provider` field extracted into metadata

**Step 3: Run tests, fix, commit**

---

### Task 3: Fix `openrouter_options.ml` — Match upstream settings exactly

The upstream `OpenRouterChatSettings` and `OpenRouterProviderOptions` types expose a very different set of options than the current OCaml type. We need to:

1. **Remove invented fields:** `transforms`, `route` (the upstream has no `transforms` or `route` fields)
2. **Add `reasoning` object** (replaces the deprecated `include_reasoning` boolean): `{ enabled; exclude; max_tokens; effort }`
3. **Expand `provider` preferences** to match upstream: add `data_collection`, `only`, `ignore`, `quantizations`, `sort`, `max_price`, `zdr`
4. **Expand plugins**: add `Moderation`, `Response_healing` variants; add missing sub-configs (`search_prompt`, `engine` for web; `allowed_models` for auto-router; `max_files`, `pdf_engine` for file-parser)
5. **Expand `reasoning_effort`** values: add `Xhigh`, `Minimal`, `None_`
6. **Add missing fields:** `models`, `logit_bias`, `logprobs`, `user`, `top_k`, `cache_control`, `debug`, `web_search_options`, `usage`, `extra_body`
7. **Keep `include_reasoning` as deprecated** (upstream still sends it from `settings.includeReasoning`)

**Files:**
- Modify: `lib/ai_provider_openrouter/openrouter_options.ml`
- Modify: `lib/ai_provider_openrouter/openrouter_options.mli`

**The new `t` type should look like:**

```ocaml
type reasoning_config = {
  enabled : bool option;
  exclude : bool option;
  budget : reasoning_budget;
}

and reasoning_budget =
  | Max_tokens of int
  | Effort of reasoning_effort
  | No_budget

type cache_control = { type_ : string; ttl : string option }

type debug_config = { echo_upstream_body : bool option }

type web_search_options = {
  max_results : int option;
  search_prompt : string option;
  engine : string option;
}

type usage_config = { include_ : bool }

type max_price = {
  prompt : float option;
  completion : float option;
  image : float option;
  audio : float option;
  request : float option;
}

type provider_prefs = {
  order : string list;
  allow_fallbacks : bool option;
  require_parameters : bool option;
  data_collection : string option;
  only : string list;
  ignore_ : string list;
  quantizations : string list;
  sort : string option;
  max_price : max_price option;
  zdr : bool option;
}

type t = {
  (* Model settings *)
  models : string list;
  logit_bias : (int * float) list;
  logprobs : [ `Bool of bool | `Int of int ] option;
  parallel_tool_calls : bool option;
  user : string option;
  (* Reasoning *)
  reasoning : reasoning_config option;
  include_reasoning : bool option;  (* deprecated, kept for compat *)
  (* Plugins & search *)
  plugins : plugin list;
  web_search_options : web_search_options option;
  (* Routing *)
  provider : provider_prefs option;
  (* Caching *)
  cache_control : cache_control option;
  (* Debug *)
  debug : debug_config option;
  (* Usage accounting *)
  usage : usage_config option;
  (* BYOK *)
  api_keys : (string * string) list;
  (* Extra body passthrough *)
  extra_body : (string * Yojson.Basic.t) list;
  (* Local-only settings (not sent in request body) *)
  strict_json_schema : bool;
  system_message_mode : Model_catalog.system_message_mode option;
}
```

And the plugin type should expand to:
```ocaml
type plugin =
  | Web_search of web_search_plugin_config option
  | File_parser of file_parser_plugin_config option
  | Auto_router of auto_router_plugin_config option
  | Moderation
  | Response_healing

and web_search_plugin_config = {
  max_results : int option;
  search_prompt : string option;
  engine : string option;
}

and file_parser_plugin_config = {
  max_files : int option;
  pdf_engine : string option;
}

and auto_router_plugin_config = {
  allowed_models : string list;
}
```

Also add all the JSON serialization functions for the new types.

**Step 2: Update tests and commit**

---

### Task 4: Rewrite `openrouter_api.ml` — Match upstream request body and headers

The request body needs to match the upstream `getArgs()` exactly. Headers need `X-OpenRouter-Title` (not `x-title`) and `X-Provider-API-Keys` (not body field).

**Files:**
- Modify: `lib/ai_provider_openrouter/openrouter_api.ml`
- Modify: `lib/ai_provider_openrouter/openrouter_api.mli`

**Key changes:**

1. **Remove** `transforms`, `route`, `api_keys` from request body
2. **Add** to request body: `models`, `logit_bias`, `logprobs`, `top_logprobs`, `user`, `top_k`, `reasoning`, `usage`, `plugins`, `web_search_options`, `provider`, `debug`, `cache_control`, `include_reasoning`
3. **Add `compatibility` mode** — `stream_options` only sent when `strict`
4. **Fix headers:** `X-OpenRouter-Title` instead of `x-title`; add `X-Provider-API-Keys` header for BYOK
5. **Handle HTTP 200 error responses** — check for `"error"` key in JSON response
6. **Merge `extra_body`** fields into the serialized JSON before sending

The `make_request_body` function parameters should change to accept the new fields. The `make_headers` function needs `api_keys` parameter for the header.

For `extra_body` merging: after serializing the typed request body to JSON, merge any `extra_body` key-value pairs into the resulting `Assoc` before sending.

**Step 2: Update tests, commit**

---

### Task 5: Simplify `model_catalog.ml` — Remove invented behavior

The upstream has NO model catalog. It does not:
- Detect reasoning models from model IDs
- Set default max tokens
- Auto-configure system message mode

The `:thinking` suffix classification can stay as a **helper** (it's useful for the `system_message_mode` default), but it must NOT inject `default_max_tokens` or suppress/transform any parameters.

**Files:**
- Modify: `lib/ai_provider_openrouter/model_catalog.ml`
- Modify: `lib/ai_provider_openrouter/model_catalog.mli`
- Modify: `test/ai_provider_openrouter/test_model_catalog.ml`

**Key changes:**
1. Remove `default_max_tokens` from capabilities (or keep it but don't use it)
2. The only thing we keep from model_catalog is `system_message_mode` inference for the `:thinking` suffix → `Developer`. This is a reasonable local convenience since the OpenAI converter needs a system_message_mode and the upstream relies on the caller to configure it.
3. Remove `supports_structured_output`, `supports_vision`, `supports_tool_calling` — these are not used anywhere and are invented.

**Simplified type:**
```ocaml
type system_message_mode = Ai_provider_openai.Model_catalog.system_message_mode =
  | System
  | Developer
  | Remove

(** Infer system_message_mode from model ID.
    [:thinking] suffix → Developer, everything else → System.
    Users can override via Openrouter_options.system_message_mode. *)
val infer_system_message_mode : string -> system_message_mode
```

---

### Task 6: Rewrite `openrouter_model.ml` — Match upstream request assembly

This is the main orchestration module. It needs to:

1. **Stop injecting `default_max_tokens`** — send `None` when caller doesn't specify
2. **Pass through all new fields** from `openrouter_options` to the request body
3. **Handle `extra_body` merging** — merge user's extra_body fields into the JSON
4. **Send `api_keys` via headers** not body
5. **Remove `transforms` and `route`** from request assembly
6. **Add `compatibility` parameter** — default to `Compatible` (upstream defaults to `compatible`)

**Files:**
- Modify: `lib/ai_provider_openrouter/openrouter_model.ml`

**Key logic changes in `prepare_request`:**
- Don't fall back to `model_caps.default_max_tokens`
- Pass `models`, `logit_bias`, `logprobs`, `top_logprobs`, `user`, `top_k` from options
- Pass `reasoning`, `include_reasoning`, `usage`, `web_search_options`, `debug`, `cache_control`, `provider` from options
- Remove `transforms`, `route`, `reasoning_effort` (replaced by `reasoning` object)
- Merge `extra_body` into the serialized JSON

---

### Task 7: Fix `openrouter_error.ml` — Match upstream error handling

The upstream:
- Does NOT classify error types
- Does NOT prepend `[retryable]`
- DOES extract richer messages from `error.metadata.raw` and `error.metadata.provider_name`
- Uses `createJsonErrorResponseHandler` from provider-utils

**Files:**
- Modify: `lib/ai_provider_openrouter/openrouter_error.ml`

**Key changes:**
1. Remove `openrouter_error_type`, `error_type_of_string`, `is_retryable`
2. Add `extractErrorMessage` equivalent: check `error.metadata.provider_name` and `error.metadata.raw` for richer messages
3. Keep the basic `of_response` function but with the improved message extraction

```ocaml
let extract_raw_message raw =
  (* Recursively extract message from raw upstream error *)
  match raw with
  | `String s ->
    (try
      let parsed = Yojson.Basic.from_string s in
      extract_raw_message parsed
    with Yojson.Json_error _ -> Some s)
  | `Assoc fields ->
    let try_field name =
      match List.assoc_opt name fields with
      | Some (`String s) when String.length s > 0 -> Some s
      | Some (`Assoc _ as nested) -> extract_raw_message nested
      | _ -> None
    in
    (* Try common error message fields in order *)
    List.find_map try_field ["message"; "error"; "detail"; "details"; "msg"]
  | _ -> None

let extract_error_message error_json =
  match error_json with
  | `Assoc fields ->
    let message =
      match List.assoc_opt "message" fields with
      | Some (`String m) -> m
      | _ -> "Unknown error"
    in
    let metadata =
      match List.assoc_opt "metadata" fields with
      | Some (`Assoc _ as m) -> Some m
      | _ -> None
    in
    (match metadata with
    | Some (`Assoc meta_fields) ->
      let parts = ref [] in
      (match List.assoc_opt "provider_name" meta_fields with
      | Some (`String name) when String.length name > 0 ->
        parts := Printf.sprintf "[%s]" name :: !parts
      | _ -> ());
      let raw_msg =
        match List.assoc_opt "raw" meta_fields with
        | Some raw -> extract_raw_message raw
        | None -> None
      in
      (match raw_msg with
      | Some m when not (String.equal m message) -> parts := m :: !parts
      | _ -> parts := message :: !parts);
      String.concat " " (List.rev !parts)
    | _ -> message)
  | _ -> "Unknown error"

let of_response ~status ~body =
  let message =
    try
      let json = Yojson.Basic.from_string body in
      match json with
      | `Assoc fields ->
        (match List.assoc_opt "error" fields with
        | Some error_json -> extract_error_message error_json
        | None -> body)
      | _ -> body
    with Yojson.Json_error _ -> body
  in
  { Ai_provider.Provider_error.provider = "openrouter"; kind = Api_error { status; body = message } }
```

---

### Task 8: Fix `config.ml` — Add `compatibility` mode and `api_keys`

**Files:**
- Modify: `lib/ai_provider_openrouter/config.ml`

**Changes:**
1. Add `compatibility` type: `Strict | Compatible`
2. Add `compatibility` field to `t` (default: `Compatible`)
3. Add `api_keys` field to config (for the `X-Provider-API-Keys` header)
4. Keep `app_title` / `app_url` field names (internal — the header name fix is in `openrouter_api.ml`)

---

### Task 9: Fix `convert_stream.ml` — Parse `reasoning_details` in streaming, fix `[DONE]` handling

**Files:**
- Modify: `lib/ai_provider_openrouter/convert_stream.ml`
- Modify: `test/ai_provider_openrouter/test_convert_stream.ml`

**Key changes:**
1. Add `reasoning_details` parsing to the delta type (same types as in convert_response)
2. Process `reasoning_details` deltas — emit `Reasoning` parts for text/summary types, `[REDACTED]` for encrypted
3. Fall back to legacy `delta.reasoning` when `reasoning_details` is absent
4. **Fix `[DONE]` handling** — use the accumulated finish reason from chunks, not hardcoded `Stop`
5. Handle error chunks in stream (check for `"error"` key in chunk JSON)
6. Track finish reason from `choice.finish_reason` across chunks
7. Apply finish-reason overrides: tool_calls + encrypted reasoning + `stop` → `Tool_calls`; tool_calls + `Other` → `Tool_calls`

---

### Task 10: Update `ai_provider_openrouter.ml` facade and fix all downstream references

**Files:**
- Modify: `lib/ai_provider_openrouter/ai_provider_openrouter.ml`
- Modify: `test/ai_provider_openrouter/test_openrouter_model.ml`
- Modify: `test/ai_provider_openrouter/test_model_catalog.ml`

**Changes:**
1. Add `compatibility` parameter to `language_model`, `create` functions
2. Pass `api_keys` through config for header generation
3. Update `test_openrouter_model.ml` — update the `test_openrouter_options_in_request` test to use the new options shape (no `route`, no `transforms`)
4. Update `test_model_catalog.ml` — simplify to match the reduced model_catalog API
5. Add a test for `reasoning_details` in response parsing (end-to-end through the model)
6. Add a test verifying `X-OpenRouter-Title` and `X-Provider-API-Keys` headers

---

### Task 11: Final integration test — verify wire format matches upstream

**Files:**
- Modify: `test/ai_provider_openrouter/test_openrouter_model.ml`

**Add integration-style tests that verify the exact JSON body and headers sent:**

1. **Test: request body with all options** — set plugins, provider, reasoning, cache_control, etc. and verify the JSON body matches what the upstream would send
2. **Test: streaming response with reasoning_details** — mock a stream with `reasoning_details` chunks and verify the output parts
3. **Test: HTTP 200 error response** — mock a 200 response with `{"error": {"message": "...", "code": 400}}` and verify it throws
4. **Test: extra_body merging** — set extra_body options and verify they appear in the request JSON
5. **Test: api_keys sent as header** — verify `X-Provider-API-Keys` header is set, not a body field

**Step: Run all tests**

Run: `dune runtest test/ai_provider_openrouter 2>&1`
Expected: All tests pass

**Step: Commit**

```bash
git add -A
git commit -m "feat(openrouter): achieve upstream wire-format parity"
```

---

## Execution Order

Tasks 1-2 can be done independently. Task 3 must be done before tasks 4 and 6. Task 5 should be done before task 6. Task 7-8 are independent. Task 9 depends on Task 1 (usage types). Task 10-11 depend on everything else.

Recommended serial order: 1 → 2 → 3 → 5 → 4 → 8 → 7 → 6 → 9 → 10 → 11

Note: Because many files reference each other, expect compilation failures between tasks. The code will compile as a whole after task 10 brings everything together.
