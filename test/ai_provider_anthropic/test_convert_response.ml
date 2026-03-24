(* Finish reason mapping *)
let test_stop_reason_end_turn () =
  let r = Ai_provider_anthropic.Convert_response.map_stop_reason (Some "end_turn") in
  Alcotest.(check string) "stop" "stop" (Ai_provider.Finish_reason.to_string r)

let test_stop_reason_max_tokens () =
  let r = Ai_provider_anthropic.Convert_response.map_stop_reason (Some "max_tokens") in
  Alcotest.(check string) "length" "length" (Ai_provider.Finish_reason.to_string r)

let test_stop_reason_tool_use () =
  let r = Ai_provider_anthropic.Convert_response.map_stop_reason (Some "tool_use") in
  Alcotest.(check string) "tool_calls" "tool_calls" (Ai_provider.Finish_reason.to_string r)

let test_stop_reason_none () =
  let r = Ai_provider_anthropic.Convert_response.map_stop_reason None in
  Alcotest.(check string) "unknown" "unknown" (Ai_provider.Finish_reason.to_string r)

(* Parse response *)
let test_parse_text_response () =
  let json =
    Yojson.Safe.from_string
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
  | [ Ai_provider.Content.Text { text } ] -> Alcotest.(check string) "text" "Hello!" text
  | _ -> Alcotest.fail "expected single text");
  Alcotest.(check string) "finish" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  Alcotest.(check int) "input" 10 result.usage.input_tokens

let test_parse_tool_use_response () =
  let json =
    Yojson.Safe.from_string
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
  Alcotest.(check int) "2 content" 2 (List.length result.content);
  Alcotest.(check string) "finish" "tool_calls" (Ai_provider.Finish_reason.to_string result.finish_reason)

let test_parse_thinking_response () =
  let json =
    Yojson.Safe.from_string
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
  Alcotest.(check int) "2 content" 2 (List.length result.content);
  match List.nth result.content 0 with
  | Ai_provider.Content.Reasoning { text; signature; _ } ->
    Alcotest.(check string) "thinking" "Let me reason..." text;
    Alcotest.(check (option string)) "sig" (Some "sig_abc") signature
  | _ -> Alcotest.fail "expected Reasoning"

(* Error parsing *)
let test_error_parsing () =
  let err =
    Ai_provider_anthropic.Anthropic_error.of_response ~status:401
      ~body:{|{"error":{"type":"authentication_error","message":"Invalid API key"}}|}
  in
  Alcotest.(check string) "provider" "anthropic" err.provider;
  match err.kind with
  | Ai_provider.Provider_error.Api_error { status; _ } -> Alcotest.(check int) "status" 401 status
  | _ -> Alcotest.fail "expected Api_error"

let test_is_retryable () =
  Alcotest.(check bool) "rate limit" true (Ai_provider_anthropic.Anthropic_error.is_retryable Rate_limit_error);
  Alcotest.(check bool) "overloaded" true (Ai_provider_anthropic.Anthropic_error.is_retryable Overloaded_error);
  Alcotest.(check bool) "auth" false (Ai_provider_anthropic.Anthropic_error.is_retryable Authentication_error)

(* Usage conversion *)
let test_usage_conversion () =
  let json = Yojson.Safe.from_string {|{"input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 80}|} in
  let usage =
    match Ai_provider_anthropic.Convert_usage.anthropic_usage_of_yojson json with
    | Ok u -> u
    | Error e -> Alcotest.fail ("Failed to parse usage: " ^ e)
  in
  let sdk_usage = Ai_provider_anthropic.Convert_usage.to_usage usage in
  Alcotest.(check int) "input" 100 sdk_usage.input_tokens;
  Alcotest.(check int) "output" 50 sdk_usage.output_tokens;
  Alcotest.(check (option int)) "total" (Some 150) sdk_usage.total_tokens

let () =
  Alcotest.run "Convert_response"
    [
      ( "stop_reason",
        [
          Alcotest.test_case "end_turn" `Quick test_stop_reason_end_turn;
          Alcotest.test_case "max_tokens" `Quick test_stop_reason_max_tokens;
          Alcotest.test_case "tool_use" `Quick test_stop_reason_tool_use;
          Alcotest.test_case "none" `Quick test_stop_reason_none;
        ] );
      ( "parse_response",
        [
          Alcotest.test_case "text" `Quick test_parse_text_response;
          Alcotest.test_case "tool_use" `Quick test_parse_tool_use_response;
          Alcotest.test_case "thinking" `Quick test_parse_thinking_response;
        ] );
      ( "error",
        [
          Alcotest.test_case "parsing" `Quick test_error_parsing;
          Alcotest.test_case "retryable" `Quick test_is_retryable;
        ] );
      "usage", [ Alcotest.test_case "conversion" `Quick test_usage_conversion ];
    ]
