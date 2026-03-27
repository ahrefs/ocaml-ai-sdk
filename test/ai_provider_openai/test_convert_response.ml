open Alcotest

let test_finish_reason_stop () =
  let r = Ai_provider_openai.Convert_response.map_finish_reason (Some "stop") in
  match r with
  | Ai_provider.Finish_reason.Stop -> ()
  | _ -> fail "expected Stop"

let test_finish_reason_length () =
  let r = Ai_provider_openai.Convert_response.map_finish_reason (Some "length") in
  match r with
  | Ai_provider.Finish_reason.Length -> ()
  | _ -> fail "expected Length"

let test_finish_reason_tool_calls () =
  let r = Ai_provider_openai.Convert_response.map_finish_reason (Some "tool_calls") in
  match r with
  | Ai_provider.Finish_reason.Tool_calls -> ()
  | _ -> fail "expected Tool_calls"

let test_finish_reason_function_call () =
  let r = Ai_provider_openai.Convert_response.map_finish_reason (Some "function_call") in
  match r with
  | Ai_provider.Finish_reason.Tool_calls -> ()
  | _ -> fail "expected Tool_calls"

let test_finish_reason_content_filter () =
  let r = Ai_provider_openai.Convert_response.map_finish_reason (Some "content_filter") in
  match r with
  | Ai_provider.Finish_reason.Content_filter -> ()
  | _ -> fail "expected Content_filter"

let test_finish_reason_none () =
  let r = Ai_provider_openai.Convert_response.map_finish_reason None in
  match r with
  | Ai_provider.Finish_reason.Unknown -> ()
  | _ -> fail "expected Unknown"

let test_parse_text_response () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "chatcmpl-123",
        "model": "gpt-4o",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "Hello!"
          },
          "finish_reason": "stop"
        }],
        "usage": {
          "prompt_tokens": 10,
          "completion_tokens": 5,
          "total_tokens": 15
        }
      }|}
  in
  let result = Ai_provider_openai.Convert_response.parse_response json in
  (check int) "content" 1 (List.length result.content);
  (match result.content with
  | Text { text } :: _ -> (check string) "text" "Hello!" text
  | _ -> fail "expected Text as first content");
  (check int) "input_tokens" 10 result.usage.input_tokens;
  (check int) "output_tokens" 5 result.usage.output_tokens

let test_parse_tool_call_response () =
  let json =
    Yojson.Basic.from_string
      {|{
        "id": "chatcmpl-456",
        "model": "gpt-4o",
        "choices": [{
          "index": 0,
          "message": {
            "role": "assistant",
            "content": null,
            "tool_calls": [{
              "id": "call_abc",
              "type": "function",
              "function": {
                "name": "get_weather",
                "arguments": "{\"city\":\"NYC\"}"
              }
            }]
          },
          "finish_reason": "tool_calls"
        }],
        "usage": {
          "prompt_tokens": 20,
          "completion_tokens": 10
        }
      }|}
  in
  let result = Ai_provider_openai.Convert_response.parse_response json in
  (check int) "content" 1 (List.length result.content);
  (match result.content with
  | Tool_call { tool_call_id; tool_name; args; _ } :: _ ->
    (check string) "id" "call_abc" tool_call_id;
    (check string) "name" "get_weather" tool_name;
    (check string) "args" {|{"city":"NYC"}|} args
  | _ -> fail "expected Tool_call as first content");
  match result.finish_reason with
  | Tool_calls -> ()
  | _ -> fail "expected Tool_calls finish reason"

let test_parse_empty_choices () =
  let json = Yojson.Basic.from_string {|{"choices": [], "usage": {"prompt_tokens": 0, "completion_tokens": 0}}|} in
  let result = Ai_provider_openai.Convert_response.parse_response json in
  (check int) "content" 0 (List.length result.content)

let () =
  run "Convert_response"
    [
      ( "finish_reason",
        [
          test_case "stop" `Quick test_finish_reason_stop;
          test_case "length" `Quick test_finish_reason_length;
          test_case "tool_calls" `Quick test_finish_reason_tool_calls;
          test_case "function_call" `Quick test_finish_reason_function_call;
          test_case "content_filter" `Quick test_finish_reason_content_filter;
          test_case "none" `Quick test_finish_reason_none;
        ] );
      ( "parse_response",
        [
          test_case "text" `Quick test_parse_text_response;
          test_case "tool_call" `Quick test_parse_tool_call_response;
          test_case "empty_choices" `Quick test_parse_empty_choices;
        ] );
    ]
