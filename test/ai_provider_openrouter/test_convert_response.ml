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
          "cache_read_tokens": 80,
          "cache_write_tokens": 20,
          "reasoning_tokens": 10
        }
      }|}
  in
  let result = Ai_provider_openrouter.Convert_response.parse_response json in
  (check int) "input_tokens" 100 result.usage.input_tokens;
  (check int) "output_tokens" 50 result.usage.output_tokens;
  (* Check extended metadata *)
  let metadata =
    Ai_provider.Provider_options.find Ai_provider_openrouter.Convert_usage.Openrouter_usage result.provider_metadata
  in
  (match metadata with
  | Some m ->
    (check int) "cache_read_tokens" 80 m.cache_read_tokens;
    (check int) "cache_write_tokens" 20 m.cache_write_tokens;
    (check int) "reasoning_tokens" 10 m.reasoning_tokens
  | None -> fail "expected openrouter usage metadata")

let test_finish_reason_mapping () =
  let open Ai_provider_openrouter.Convert_response in
  (check string) "stop" "stop"
    (Ai_provider.Finish_reason.to_string (map_finish_reason (Some "stop")));
  (check string) "length" "length"
    (Ai_provider.Finish_reason.to_string (map_finish_reason (Some "length")));
  (check string) "tool_calls" "tool_calls"
    (Ai_provider.Finish_reason.to_string (map_finish_reason (Some "tool_calls")));
  (check string) "none" "unknown"
    (Ai_provider.Finish_reason.to_string (map_finish_reason None))

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
        ] );
    ]
