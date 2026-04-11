open Alcotest

let test_parse_basic_response () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-123",
        "model": "openai/gpt-4o",
        "choices": [{
          "index": 0,
          "message": {"role": "assistant", "content": "Hello!"},
          "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (check int) "one content" 1 (List.length result.content);
  (match result.content with
  | Text { text } :: _ -> (check string) "text" "Hello!" text
  | _ -> fail "expected Text content");
  (check int) "input_tokens" 10 result.usage.input_tokens;
  (check int) "output_tokens" 5 result.usage.output_tokens

let test_parse_response_with_reasoning () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-456",
        "model": "anthropic/claude-3.5-sonnet",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "The answer is 42.",
            "reasoning": "Let me think about this step by step..."
          },
          "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 20, "completion_tokens": 30, "total_tokens": 50}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (match result.content with
  | [ Reasoning { text = r; _ }; Text { text = t } ] ->
    (check string) "reasoning" "Let me think about this step by step..." r;
    (check string) "text" "The answer is 42." t
  | _ -> fail "expected [Reasoning; Text] content")

let test_parse_response_with_tool_calls () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-789",
        "model": "openai/gpt-4o",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": null,
            "tool_calls": [{
              "id": "call_1",
              "type": "function",
              "function": {"name": "get_weather", "arguments": "{\"city\":\"London\"}"}
            }]
          },
          "finish_reason": "tool_calls"
        }],
        "usage": {"prompt_tokens": 15, "completion_tokens": 10}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (check int) "one tool call" 1 (List.length result.content);
  (match result.content with
  | Tool_call { tool_name; tool_call_id; args; _ } :: _ ->
    (check string) "tool_name" "get_weather" tool_name;
    (check string) "tool_call_id" "call_1" tool_call_id;
    (check string) "args" {|{"city":"London"}|} args
  | _ -> fail "expected Tool_call content")

let test_parse_response_with_extended_usage () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-ext",
        "model": "anthropic/claude-3.5-sonnet",
        "choices": [{
          "index": 0,
          "message": {"role": "assistant", "content": "Hi"},
          "finish_reason": "stop"
        }],
        "usage": {
          "prompt_tokens": 100,
          "completion_tokens": 50,
          "total_tokens": 150,
          "prompt_tokens_details": {"cached_tokens": 80},
          "completion_tokens_details": {"reasoning_tokens": 10}
        }
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (check int) "input_tokens" 100 result.usage.input_tokens;
  (check int) "output_tokens" 50 result.usage.output_tokens;
  let metadata =
    Ai_provider.Provider_options.find Ai_provider_openrouter.Convert_usage.Openrouter_usage result.provider_metadata
  in
  (match metadata with
  | Some m ->
    (check int) "cache_read_tokens" 80 m.cache_read_tokens;
    (check int) "reasoning_tokens" 10 m.reasoning_tokens
  | None -> fail "expected openrouter usage metadata")

let test_finish_reason_mapping () =
  let open Ai_provider_openrouter.Convert_response in
  (check string) "stop" "stop"
    (Ai_provider.Finish_reason.to_string (map_finish_reason (Some "stop")));
  (check string) "length" "length"
    (Ai_provider.Finish_reason.to_string (map_finish_reason (Some "length")));
  (check string) "tool_calls" "tool-calls"
    (Ai_provider.Finish_reason.to_string (map_finish_reason (Some "tool_calls")));
  (check string) "none" "unknown"
    (Ai_provider.Finish_reason.to_string (map_finish_reason None))

let test_parse_response_with_reasoning_details () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-rd1",
        "model": "openai/o1",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "The answer is 42.",
            "reasoning_details": [
              {"type": "reasoning.text", "text": "Step by step thinking...", "signature": "sig123"}
            ]
          },
          "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (match result.content with
  | [ Reasoning { text; signature; _ }; Text { text = t } ] ->
    (check string) "reasoning text" "Step by step thinking..." text;
    (check (option string)) "signature" (Some "sig123") signature;
    (check string) "content text" "The answer is 42." t
  | _ -> fail "expected [Reasoning; Text] content")

let test_parse_response_with_encrypted_reasoning () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-rd2",
        "model": "openai/o1",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "Done.",
            "reasoning_details": [
              {"type": "reasoning.encrypted", "data": "encrypted-blob-abc"}
            ]
          },
          "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (match result.content with
  | [ Reasoning { text; signature; _ }; Text { text = t } ] ->
    (check string) "encrypted reasoning" "[REDACTED]" text;
    (check (option string)) "no signature" None signature;
    (check string) "content text" "Done." t
  | _ -> fail "expected [Reasoning; Text] content")

let test_parse_response_with_summary_reasoning () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-rd3",
        "model": "openai/o1",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "Result.",
            "reasoning_details": [
              {"type": "reasoning.summary", "summary": "I considered multiple approaches."}
            ]
          },
          "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (match result.content with
  | [ Reasoning { text; _ }; Text { text = t } ] ->
    (check string) "summary reasoning" "I considered multiple approaches." text;
    (check string) "content text" "Result." t
  | _ -> fail "expected [Reasoning; Text] content")

let test_reasoning_details_fallback_to_legacy () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-legacy",
        "model": "anthropic/claude-3.5-sonnet",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "Answer.",
            "reasoning": "Legacy reasoning string",
            "reasoning_details": []
          },
          "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (match result.content with
  | [ Reasoning { text; _ }; Text { text = t } ] ->
    (check string) "legacy reasoning" "Legacy reasoning string" text;
    (check string) "content text" "Answer." t
  | _ -> fail "expected [Reasoning; Text] content from legacy fallback")

let test_finish_reason_override_encrypted_tool_calls () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-override1",
        "model": "openai/o1",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": null,
            "reasoning_details": [
              {"type": "reasoning.encrypted", "data": "encrypted-blob"}
            ],
            "tool_calls": [{
              "id": "call_1",
              "type": "function",
              "function": {"name": "get_weather", "arguments": "{}"}
            }]
          },
          "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (check string) "finish_reason overridden to tool_calls" "tool-calls"
    (Ai_provider.Finish_reason.to_string result.finish_reason)

let test_finish_reason_override_other_tool_calls () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-override2",
        "model": "openai/o1",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": null,
            "tool_calls": [{
              "id": "call_2",
              "type": "function",
              "function": {"name": "search", "arguments": "{}"}
            }]
          },
          "finish_reason": "some_other_reason"
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (check string) "finish_reason overridden to tool_calls" "tool-calls"
    (Ai_provider.Finish_reason.to_string result.finish_reason)

let test_provider_field_extracted () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "gen-prov",
        "model": "openai/gpt-4o",
        "provider": "Azure",
        "choices": [{
          "index": 0,
          "message": {"role": "assistant", "content": "Hi"},
          "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5}
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  let provider =
    Ai_provider.Provider_options.find Ai_provider_openrouter.Convert_response.Openrouter_provider
      result.provider_metadata
  in
  (match provider with
  | Some p -> (check string) "provider" "Azure" p
  | None -> fail "expected provider metadata")

let () =
  run "Convert_response"
    [
      ( "convert_response",
        [
          test_case "basic_response" `Quick test_parse_basic_response;
          test_case "response_with_reasoning" `Quick test_parse_response_with_reasoning;
          test_case "response_with_tool_calls" `Quick test_parse_response_with_tool_calls;
          test_case "extended_usage" `Quick test_parse_response_with_extended_usage;
          test_case "finish_reason_mapping" `Quick test_finish_reason_mapping;
          test_case "reasoning_details_text" `Quick test_parse_response_with_reasoning_details;
          test_case "reasoning_details_encrypted" `Quick test_parse_response_with_encrypted_reasoning;
          test_case "reasoning_details_summary" `Quick test_parse_response_with_summary_reasoning;
          test_case "reasoning_details_fallback" `Quick test_reasoning_details_fallback_to_legacy;
          test_case "finish_reason_override_encrypted" `Quick test_finish_reason_override_encrypted_tool_calls;
          test_case "finish_reason_override_other" `Quick test_finish_reason_override_other_tool_calls;
          test_case "provider_field" `Quick test_provider_field_extracted;
        ] );
    ]
