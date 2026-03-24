# Missing Test Surface

Findings from test audit of the provider abstraction and Anthropic provider implementation.
Prioritized by impact — critical gaps first.

---

## Critical — Untested code handling real API data

### 1. `body_to_line_stream` (anthropic_api.ml)

The raw HTTP chunk-to-line parser that feeds the entire streaming pipeline.
Handles `\n`/`\r` splitting, buffer flushing, and chunk boundaries. Zero tests.

```ocaml
(* Test cases needed: *)
(* - Single chunk with multiple lines *)
(* - Line split across two chunks ("hel", "lo\n") *)
(* - \r\n line endings *)
(* - Empty chunks *)
(* - Trailing data without final \n (flush behavior) *)
(* - Large single line *)
```

**How to test:** Extract `body_to_line_stream` to accept a `string Lwt_stream.t`
(it already does internally via `Cohttp_lwt.Body.to_stream`). Create a helper
that builds a `string Lwt_stream.t` from a list of chunk strings, feed it
through, and collect the output lines.

### 2. Convert_stream error paths (convert_stream.ml)

The `"error"` event type handler (lines ~86-100) and the outer `with exn`
deserialization error catch (lines ~101-110) are completely untested. These are
the only error recovery paths in the streaming pipeline.

```ocaml
(* Test cases needed: *)
(* - SSE event with type "error" and valid error JSON *)
(* - SSE event with type "error" and malformed JSON *)
(* - SSE event with valid event type but invalid JSON data *)
(*   (triggers the with exn catch -> Stream_part.Error) *)
```

### 3. Anthropic_model.stream path (anthropic_model.ml)

The entire `stream` method is untested. The mock `fetch_fn` type only returns
`Yojson.Safe.t Lwt.t`, so the `\`Stream` path through `messages` is never
exercised.

**How to fix:** Either:
- (a) Change `Config.fetch_fn` to return the same `[\`Json | \`Stream]` variant
  as `Anthropic_api.messages`, enabling streaming mock tests.
- (b) Test at a lower level: feed a mock `Sse.event Lwt_stream.t` directly to
  `Convert_stream.transform` (partially covered by test_convert_stream, but
  without the `prepare_request` -> `messages` -> SSE parse chain).

Option (a) is recommended — it enables true E2E streaming tests.

### 4. HTTP error handling (anthropic_api.ml)

The real HTTP path's 4xx/5xx error conversion (`status >= 400` ->
`Anthropic_error.of_response` -> `Provider_error` exception) is only tested
through `Anthropic_error.of_response` in isolation, never through the
`messages` function. The exception propagation path is untested.

**How to test:** With option (a) above, the mock fetch could return an error
response. Or add a `fetch_fn` variant that raises `Provider_error` directly.

---

## Important — Edge cases and error paths

### 5. Anthropic_error.of_response with malformed JSON

The catch branch that handles non-JSON error bodies (e.g., plain text from a
proxy like "502 Bad Gateway") is untested.

```ocaml
(* Test: *)
let err = Anthropic_error.of_response ~status:502 ~body:"Bad Gateway" in
(* Should use "Bad Gateway" as the error message, not crash *)
```

### 6. Convert_prompt file/image conversion

`convert_user_part` with `File` for images vs documents, the `invalid_arg`
for URL documents, `file_data_to_image_source` with all `file_data` variants.

```ocaml
(* Test cases needed: *)
(* - File with media_type "image/png" -> A_image with Base64_image source *)
(* - File with media_type "application/pdf" -> A_document *)
(* - File with Url data and non-image type -> invalid_arg *)
(* - File with Bytes data -> Base64 encoded *)
```

### 7. Convert_prompt tool result fallback

When `tr.content` is empty, the code falls back to `tr.result` JSON.

```ocaml
(* Test: tool_result with content=[] and result=`String "answer" *)
(* Should produce Tool_text "answer" *)
```

### 8. SSE multi-line data

The SSE spec says multiple `data:` lines are joined with `\n`. The parser
implements this but it's untested.

```ocaml
(* Test: *)
(* "event: message_start\ndata: {\"a\":\n data: 1}\n\n" *)
(* Should produce event with data = "{\"a\":\n1}" *)
```

### 9. SSE flush on stream end

If the input stream ends without a trailing empty line, `emit()` is called
to flush the pending event. Untested.

### 10. Model-aware max_tokens in request body

`prepare_request` uses `Model_catalog.of_model_id` and `default_max_tokens`
when `max_output_tokens` is None. No test verifies the resulting JSON body
has the correct model-specific default.

```ocaml
(* Test: generate with model "claude-opus-4-6" and no max_output_tokens *)
(* Request body should have "max_tokens": 128000 *)
```

### 11. message_delta without usage

The fallback producing zero-token usage when the `usage` field is missing
from `message_delta` SSE events is untested.

### 12. Unknown content block type

`parse_content_block` returns `None` for unknown types, silently filtered by
`List.filter_map`. Should be tested to document the behavior.

---

## Nice to have — Additional confidence

### 13. Convert_prompt JSON serialization variants

Only `A_text` is tested. Missing: `A_image`, `A_document`, `A_tool_use`,
`A_tool_result`, `A_thinking` serialization, plus `Url_image` source and
`anthropic_message_to_yojson`.

### 14. Convert_tools JSON serialization

`anthropic_tool_choice_to_yojson` for Auto/Any/Tool variants is untested.

### 15. Middleware wrapping stream

Only the `generate` path through middleware is tested. The `stream` wrap
is never exercised.

### 16. Provider_error.to_string content

Currently just checks `String.length > 0`. Should verify actual output
for all three `error_kind` variants.

### 17. Convert_usage to_provider_metadata

The `Cache_metrics` GADT key round-trip is untested.

### 18. make_request_body optional fields

`tools`, `top_p`, `top_k`, `stop_sequences` are untested in the request
body builder.

### 19. Type-only abstraction tests

`test_prompt.ml` and `test_tool_mode_content.ml` only construct types and
pattern match them back — the compiler already guarantees this. These could
be replaced with behavioral tests if functions are added to these modules,
or removed to reduce noise.

---

## Recommended approach

1. Fix critical item 3 first (change `fetch_fn` to return `[\`Json | \`Stream]`)
   — this unblocks streaming E2E tests and HTTP error tests.
2. Add `body_to_line_stream` unit tests (critical item 1).
3. Add stream error path tests (critical item 2).
4. Add the important edge case tests (items 5-12).
5. Nice-to-have items can be added incrementally.
