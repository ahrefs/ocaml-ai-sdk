open Alcotest

(* Finish reason mapping *)
let test_stop_reason_end_turn () =
  let r = Ai_provider_anthropic.Convert_response.map_stop_reason (Some "end_turn") in
  (check string) "stop" "stop" (Ai_provider.Finish_reason.to_string r)

let test_stop_reason_max_tokens () =
  let r = Ai_provider_anthropic.Convert_response.map_stop_reason (Some "max_tokens") in
  (check string) "length" "length" (Ai_provider.Finish_reason.to_string r)

let test_stop_reason_tool_use () =
  let r = Ai_provider_anthropic.Convert_response.map_stop_reason (Some "tool_use") in
  (check string) "tool_calls" "tool-calls" (Ai_provider.Finish_reason.to_string r)

let test_stop_reason_none () =
  let r = Ai_provider_anthropic.Convert_response.map_stop_reason None in
  (check string) "unknown" "other" (Ai_provider.Finish_reason.to_string r)

(* Parse response *)
let test_parse_text_response () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "msg_123",
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": "Hello!"}],
        "model": "claude-sonnet-4-6",
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 10, "output_tokens": 5}
      }|}
  in
  let result = Ai_provider_anthropic.Convert_response.parse_response json in
  (match result.content with
  | [ Ai_provider.Content.Text { text } ] -> (check string) "text" "Hello!" text
  | _ -> fail "expected single text");
  (check string) "finish" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  (check int) "input" 10 result.usage.input_tokens

let test_parse_tool_use_response () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "msg_456",
        "content": [
          {"type": "text", "text": "Let me search."},
          {"type": "tool_use", "id": "tc_1", "name": "search", "input": {"query": "test"}}
        ],
        "model": "claude-sonnet-4-6",
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 20, "output_tokens": 15}
      }|}
  in
  let result = Ai_provider_anthropic.Convert_response.parse_response json in
  (check int) "2 content" 2 (List.length result.content);
  (check string) "finish" "tool-calls" (Ai_provider.Finish_reason.to_string result.finish_reason)

let test_parse_thinking_response () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "msg_789",
        "content": [
          {"type": "thinking", "thinking": "Let me reason...", "signature": "sig_abc"},
          {"type": "text", "text": "The answer is 42."}
        ],
        "model": "claude-sonnet-4-6",
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 30, "output_tokens": 25}
      }|}
  in
  let result = Ai_provider_anthropic.Convert_response.parse_response json in
  (check int) "2 content" 2 (List.length result.content);
  match result.content with
  | Ai_provider.Content.Reasoning { text; signature; provider_options } :: _ ->
    (check string) "thinking" "Let me reason..." text;
    (check (option string)) "sig" (Some "sig_abc") signature;
    (match Ai_provider.Provider_options.provider_metadata provider_options with
    | Some metadata ->
      (check string) "signature metadata" {|{"anthropic":{"signature":"sig_abc"}}|} (Yojson.Basic.to_string metadata)
    | None -> fail "expected signature metadata")
  | _ -> fail "expected Reasoning"

let test_parse_redacted_thinking_response () =
  let json =
    Yojson.Basic.from_string
      {|{
        "content": [{"type": "redacted_thinking", "data": "encrypted_reasoning"}],
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 30, "output_tokens": 25}
      }|}
  in
  let result = Ai_provider_anthropic.Convert_response.parse_response json in
  match result.content with
  | [ Ai_provider.Content.Reasoning { text; signature = None; provider_options } ] ->
    (check string) "empty text" "" text;
    (match Ai_provider.Provider_options.provider_metadata provider_options with
    | Some metadata ->
      (check string) "redacted metadata" {|{"anthropic":{"redactedData":"encrypted_reasoning"}}|}
        (Yojson.Basic.to_string metadata)
    | None -> fail "expected redacted thinking metadata")
  | _ -> fail "expected redacted Reasoning"

(* Error parsing *)
let test_error_parsing () =
  let err =
    Ai_provider_anthropic.Anthropic_error.of_response ~status:401
      ~body:{|{"error":{"type":"authentication_error","message":"Invalid API key"}}|}
  in
  (check string) "provider" "anthropic" err.provider;
  match err.kind with
  | Ai_provider.Provider_error.Api_error { status; _ } -> (check int) "status" 401 status
  | _ -> fail "expected Api_error"

let test_is_retryable () =
  (check bool) "rate limit" true (Ai_provider_anthropic.Anthropic_error.is_retryable Rate_limit_error);
  (check bool) "overloaded" true (Ai_provider_anthropic.Anthropic_error.is_retryable Overloaded_error);
  (check bool) "auth" false (Ai_provider_anthropic.Anthropic_error.is_retryable Authentication_error)

(* Usage conversion *)
let test_usage_conversion () =
  let json = Yojson.Basic.from_string {|{"input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 80}|} in
  let usage = Ai_provider_anthropic.Convert_usage.anthropic_usage_of_json json in
  let sdk_usage = Ai_provider_anthropic.Convert_usage.to_usage usage in
  (check int) "input" 100 sdk_usage.input_tokens;
  (check int) "output" 50 sdk_usage.output_tokens;
  (check (option int)) "total" (Some 150) sdk_usage.total_tokens

let test_usage_allows_extra_fields () =
  let json =
    Yojson.Basic.from_string
      {|{
        "input_tokens": 100,
        "output_tokens": 50,
        "cache_creation": {
          "ephemeral_5m_input_tokens": 12,
          "ephemeral_1h_input_tokens": 34,
          "future_cache_bucket_tokens": 56
        },
        "service_tier": "standard",
        "server_tool_use": {"web_search_requests": 1}
      }|}
  in
  let usage = Ai_provider_anthropic.Convert_usage.anthropic_usage_of_json json in
  (check int) "input" 100 usage.input_tokens;
  (check int) "output" 50 usage.output_tokens;
  (check (option string)) "service tier" (Some "standard") usage.service_tier;
  match usage.cache_creation with
  | Some cache_creation ->
    (check int) "ephemeral 5m" 12 cache_creation.ephemeral_5m_input_tokens;
    (check int) "ephemeral 1h" 34 cache_creation.ephemeral_1h_input_tokens
  | None -> fail "expected cache_creation"

let () =
  run "Convert_response"
    [
      ( "stop_reason",
        [
          test_case "end_turn" `Quick test_stop_reason_end_turn;
          test_case "max_tokens" `Quick test_stop_reason_max_tokens;
          test_case "tool_use" `Quick test_stop_reason_tool_use;
          test_case "none" `Quick test_stop_reason_none;
        ] );
      ( "parse_response",
        [
          test_case "text" `Quick test_parse_text_response;
          test_case "tool_use" `Quick test_parse_tool_use_response;
          test_case "thinking" `Quick test_parse_thinking_response;
          test_case "redacted_thinking" `Quick test_parse_redacted_thinking_response;
        ] );
      "error", [ test_case "parsing" `Quick test_error_parsing; test_case "retryable" `Quick test_is_retryable ];
      ( "usage",
        [
          test_case "conversion" `Quick test_usage_conversion;
          test_case "allows extra fields" `Quick test_usage_allows_extra_fields;
        ] );
    ]
