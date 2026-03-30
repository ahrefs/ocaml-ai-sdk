open Alcotest

let parse = Ai_core.Server_handler.parse_messages_from_body
let json s = Yojson.Basic.from_string s

(* Helper to count messages by type *)
let count_by_role msgs =
  List.fold_left
    (fun (s, u, a, t) msg ->
      match (msg : Ai_provider.Prompt.message) with
      | System _ -> s + 1, u, a, t
      | User _ -> s, u + 1, a, t
      | Assistant _ -> s, u, a + 1, t
      | Tool _ -> s, u, a, t + 1)
    (0, 0, 0, 0) msgs

(* === SSE response tests === *)

let test_make_sse_response_basic () =
  let stream, push = Lwt_stream.create () in
  push (Some "data: {\"type\":\"start\"}\n\n");
  push (Some "data: [DONE]\n\n");
  push None;
  let response, body = Lwt_main.run (Ai_core.Server_handler.make_sse_response stream) in
  let headers = Cohttp.Response.headers response in
  (check (option string)) "content-type" (Some "text/event-stream") (Cohttp.Header.get headers "content-type");
  (check (option string)) "protocol" (Some "v1") (Cohttp.Header.get headers "x-vercel-ai-ui-message-stream");
  ignore (body : Cohttp_lwt.Body.t)

let test_make_sse_response_all_headers () =
  let stream, push = Lwt_stream.create () in
  push None;
  let response, _body = Lwt_main.run (Ai_core.Server_handler.make_sse_response stream) in
  let headers = Cohttp.Response.headers response in
  (check (option string)) "cache-control" (Some "no-cache") (Cohttp.Header.get headers "cache-control");
  (check (option string)) "connection" (Some "keep-alive") (Cohttp.Header.get headers "connection");
  (check (option string)) "x-accel-buffering" (Some "no") (Cohttp.Header.get headers "x-accel-buffering")

let test_make_sse_response_extra_headers () =
  let stream, push = Lwt_stream.create () in
  push None;
  let response, _body =
    Lwt_main.run (Ai_core.Server_handler.make_sse_response ~extra_headers:[ "x-custom", "value" ] stream)
  in
  let headers = Cohttp.Response.headers response in
  (check (option string)) "custom header" (Some "value") (Cohttp.Header.get headers "x-custom")

let test_make_sse_response_custom_status () =
  let stream, push = Lwt_stream.create () in
  push None;
  let response, _body = Lwt_main.run (Ai_core.Server_handler.make_sse_response ~status:`Bad_request stream) in
  let status = Cohttp.Response.status response in
  (check int) "status code" 400 (Cohttp.Code.code_of_status status)

let test_make_sse_response_body_content () =
  let stream, push = Lwt_stream.create () in
  push (Some "data: hello\n\n");
  push (Some "data: world\n\n");
  push None;
  let _response, body = Lwt_main.run (Ai_core.Server_handler.make_sse_response stream) in
  let body_str = Lwt_main.run (Cohttp_lwt.Body.to_string body) in
  (check string) "body content" "data: hello\n\ndata: world\n\n" body_str

(* === parse_messages_from_body tests === *)

let test_parse_user_text_only () =
  let msgs = parse (json {|{"messages":[{"role":"user","parts":[{"type":"text","text":"Hello"}]}]}|}) in
  (check int) "one message" 1 (List.length msgs);
  match msgs with
  | [ User { content = [ Text { text; _ } ] } ] -> (check string) "text" "Hello" text
  | _ -> fail "expected User with one Text part"

let test_parse_user_multiple_text_parts () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"user","parts":[
            {"type":"text","text":"Hello "},
            {"type":"text","text":"world!"}
          ]}]}|})
  in
  match msgs with
  | [ User { content = [ Text { text = t1; _ }; Text { text = t2; _ } ] } ] ->
    (check string) "first" "Hello " t1;
    (check string) "second" "world!" t2
  | _ -> fail "expected User with two Text parts"

let test_parse_system_message () =
  let msgs =
    parse (json {|{"messages":[{"role":"system","parts":[{"type":"text","text":"You are a helpful assistant."}]}]}|})
  in
  match msgs with
  | [ System { content } ] -> (check string) "system content" "You are a helpful assistant." content
  | _ -> fail "expected System message"

let test_parse_system_concatenates_text_parts () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"system","parts":[
            {"type":"text","text":"First. "},
            {"type":"text","text":"Second."}
          ]}]}|})
  in
  match msgs with
  | [ System { content } ] -> (check string) "concatenated" "First. Second." content
  | _ -> fail "expected System message"

let test_parse_assistant_text () =
  let msgs = parse (json {|{"messages":[{"role":"assistant","parts":[{"type":"text","text":"Hi there!"}]}]}|}) in
  match msgs with
  | [ Assistant { content = [ Text { text; _ } ] } ] -> (check string) "text" "Hi there!" text
  | _ -> fail "expected Assistant with Text"

let test_parse_assistant_reasoning () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"reasoning","text":"Let me think..."},
            {"type":"text","text":"The answer is 42."}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Reasoning { text = r; _ }; Text { text = t; _ } ] } ] ->
    (check string) "reasoning" "Let me think..." r;
    (check string) "text" "The answer is 42." t
  | _ -> fail "expected Assistant with Reasoning + Text"

let test_parse_user_file_url () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"user","parts":[
            {"type":"file","mediaType":"image/png","url":"https://example.com/img.png"}
          ]}]}|})
  in
  match msgs with
  | [ User { content = [ File { data = Url url; media_type; filename; _ } ] } ] ->
    (check string) "url" "https://example.com/img.png" url;
    (check string) "media_type" "image/png" media_type;
    (check (option string)) "filename" None filename
  | _ -> fail "expected User with File (url)"

let test_parse_user_file_base64 () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"user","parts":[
            {"type":"file","mediaType":"application/pdf","data":"aGVsbG8=","filename":"doc.pdf"}
          ]}]}|})
  in
  match msgs with
  | [ User { content = [ File { data = Base64 d; media_type; filename; _ } ] } ] ->
    (check string) "data" "aGVsbG8=" d;
    (check string) "media_type" "application/pdf" media_type;
    (check (option string)) "filename" (Some "doc.pdf") filename
  | _ -> fail "expected User with File (base64)"

let test_parse_user_text_and_file () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"user","parts":[
            {"type":"text","text":"Describe this image:"},
            {"type":"file","mediaType":"image/jpeg","url":"https://example.com/photo.jpg"}
          ]}]}|})
  in
  match msgs with
  | [ User { content = [ Text { text; _ }; File { data = Url _; _ } ] } ] ->
    (check string) "text" "Describe this image:" text
  | _ -> fail "expected User with Text + File"

let test_parse_tool_invocation_output_available () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"text","text":"Let me check..."},
            {"type":"tool-weather","toolCallId":"tc_1","toolName":"weather",
             "state":"output-available","input":{"city":"NYC"},"output":{"temp":72}}
          ]}]}|})
  in
  let s, _u, a, t = count_by_role msgs in
  (check int) "assistant msgs" 1 a;
  (check int) "tool msgs" 1 t;
  (check int) "system msgs" 0 s;
  match msgs with
  | [
   Assistant { content = [ Text { text; _ }; Tool_call { id; name; args; _ } ] };
   Tool { content = [ { tool_call_id; tool_name; result; is_error; _ } ] };
  ] ->
    (check string) "text" "Let me check..." text;
    (check string) "tool_call id" "tc_1" id;
    (check string) "tool_call name" "weather" name;
    (check string) "args" {|{"city":"NYC"}|} (Yojson.Basic.to_string args);
    (check string) "tool_call_id" "tc_1" tool_call_id;
    (check string) "tool_name" "weather" tool_name;
    (check string) "result" {|{"temp":72}|} (Yojson.Basic.to_string result);
    (check bool) "not error" false is_error
  | _ -> fail "expected Assistant(Text+Tool_call) + Tool(result)"

let test_parse_tool_invocation_output_error () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-search","toolCallId":"tc_2","toolName":"search",
             "state":"output-error","input":{"q":"test"},"errorText":"API timeout"}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Tool_call _ ] }; Tool { content = [ { is_error; result; _ } ] } ] ->
    (check bool) "is error" true is_error;
    (check string) "error text" {|"API timeout"|} (Yojson.Basic.to_string result)
  | _ -> fail "expected Assistant(Tool_call) + Tool(error result)"

let test_parse_tool_invocation_output_denied () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-delete","toolCallId":"tc_3","toolName":"delete",
             "state":"output-denied","input":{"id":1}}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Tool_call _ ] }; Tool { content = [ { is_error; result; _ } ] } ] ->
    (check bool) "is error" true is_error;
    (check string) "denied" {|"Tool execution denied"|} (Yojson.Basic.to_string result)
  | _ -> fail "expected Assistant(Tool_call) + Tool(denied result)"

let test_parse_tool_invocation_input_available () =
  (* input-available state: tool call exists but no result yet *)
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-search","toolCallId":"tc_4","toolName":"search",
             "state":"input-available","input":{"q":"test"}}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Tool_call { id; name; _ } ] } ] ->
    (check string) "id" "tc_4" id;
    (check string) "name" "search" name
  | _ -> fail "expected Assistant(Tool_call only, no Tool message)"

let test_parse_dynamic_tool () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"dynamic-tool","toolCallId":"tc_5","toolName":"custom_tool",
             "state":"output-available","input":{"x":1},"output":{"y":2}}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Tool_call { name; _ } ] }; Tool { content = [ { tool_name; _ } ] } ] ->
    (check string) "tool name" "custom_tool" name;
    (check string) "result tool name" "custom_tool" tool_name
  | _ -> fail "expected dynamic-tool parsed as tool call + result"

let test_parse_multiple_tool_calls () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-search","toolCallId":"tc_a","toolName":"search",
             "state":"output-available","input":{"q":"first"},"output":"result1"},
            {"type":"tool-fetch","toolCallId":"tc_b","toolName":"fetch",
             "state":"output-available","input":{"url":"x"},"output":"result2"}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Tool_call { id = id1; _ }; Tool_call { id = id2; _ } ] }; Tool { content = results } ] ->
    (check string) "first id" "tc_a" id1;
    (check string) "second id" "tc_b" id2;
    (check int) "two results" 2 (List.length results)
  | _ -> fail "expected Assistant with 2 tool calls + Tool with 2 results"

let test_parse_skip_unknown_parts () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"user","parts":[
            {"type":"text","text":"Hello"},
            {"type":"unknown-future-type","data":"something"},
            {"type":"source","sourceId":"s1","url":"https://example.com","title":"Example"}
          ]}]}|})
  in
  match msgs with
  | [ User { content } ] -> (check int) "only text part" 1 (List.length content)
  | _ -> fail "expected User with only the text part"

let test_parse_skip_step_start () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"step-start"},
            {"type":"text","text":"Hello"}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Text { text; _ } ] } ] -> (check string) "text" "Hello" text
  | _ -> fail "expected Assistant with only text (step-start skipped)"

let test_parse_empty_parts () =
  let msgs = parse (json {|{"messages":[{"role":"user","parts":[]}]}|}) in
  (check int) "no messages for empty parts" 0 (List.length msgs)

let test_parse_missing_parts () =
  let msgs = parse (json {|{"messages":[{"role":"user"}]}|}) in
  (check int) "no messages when parts missing" 0 (List.length msgs)

let test_parse_multi_turn_conversation () =
  let msgs =
    parse
      (json
         {|{"messages":[
            {"role":"system","parts":[{"type":"text","text":"Be helpful."}]},
            {"role":"user","parts":[{"type":"text","text":"Hi"}]},
            {"role":"assistant","parts":[{"type":"text","text":"Hello!"}]},
            {"role":"user","parts":[{"type":"text","text":"How are you?"}]}
          ]}|})
  in
  let s, u, a, _t = count_by_role msgs in
  (check int) "system" 1 s;
  (check int) "user" 2 u;
  (check int) "assistant" 1 a

let test_parse_unknown_role_skipped () =
  let msgs =
    parse
      (json
         {|{"messages":[
            {"role":"user","parts":[{"type":"text","text":"Hi"}]},
            {"role":"function","parts":[{"type":"text","text":"result"}]}
          ]}|})
  in
  (check int) "unknown role skipped" 1 (List.length msgs)

let test_parse_invalid_json_returns_empty () =
  let msgs = parse (`String "not an object") in
  (check int) "empty on invalid" 0 (List.length msgs)

let test_parse_file_missing_media_type_skipped () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"user","parts":[
            {"type":"file","url":"https://example.com/img.png"}
          ]}]}|})
  in
  (check int) "no messages (file part skipped)" 0 (List.length msgs)

let test_parse_file_missing_data_and_url_skipped () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"user","parts":[
            {"type":"file","mediaType":"image/png"}
          ]}]}|})
  in
  (check int) "no messages (file part skipped)" 0 (List.length msgs)

let test_parse_tool_invocation_input_streaming () =
  (* input-streaming: tool call exists, model is still generating input *)
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-search","toolCallId":"tc_s","toolName":"search",
             "state":"input-streaming","input":{"q":"partial"}}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Tool_call { id; _ } ] } ] -> (check string) "id" "tc_s" id
  | _ -> fail "expected Assistant(Tool_call only, no Tool message)"

let test_parse_tool_approval_requested () =
  (* approval-requested: tool call pending approval, no result *)
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-delete","toolCallId":"tc_ap","toolName":"delete",
             "state":"approval-requested","input":{"id":42}}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Tool_call { id; name; _ } ] } ] ->
    (check string) "id" "tc_ap" id;
    (check string) "name" "delete" name
  | _ -> fail "expected Assistant(Tool_call only, no Tool message for approval-requested)"

let test_parse_tool_approval_responded_approved () =
  (* approval-responded with approved=true: tool will be executed, no result yet *)
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-weather","toolCallId":"tc_1","toolName":"weather",
             "state":"approval-responded","approved":true,"input":{"city":"London"}}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Tool_call { id; name; _ } ] } ] ->
    (check string) "id" "tc_1" id;
    (check string) "name" "weather" name
  | _ -> fail "expected Assistant(Tool_call only, no Tool message for approved)"

let test_parse_tool_approval_responded_denied () =
  (* approval-responded with approved=false: produces error tool result *)
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-weather","toolCallId":"tc_1","toolName":"weather",
             "state":"approval-responded","approved":false,"input":{"city":"London"}}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ Tool_call _ ] }; Tool { content = [ { is_error; result; tool_call_id; _ } ] } ] ->
    (check bool) "is error" true is_error;
    (check string) "denied" {|"Tool execution denied"|} (Yojson.Basic.to_string result);
    (check string) "tool_call_id" "tc_1" tool_call_id
  | _ -> fail "expected Assistant(Tool_call) + Tool(denied result)"

let test_parse_tool_output_available_null_output () =
  (* output-available without an output field defaults to `Null *)
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-noop","toolCallId":"tc_n","toolName":"noop",
             "state":"output-available","input":{}}
          ]}]}|})
  in
  match msgs with
  | [ Assistant _; Tool { content = [ { result; is_error; _ } ] } ] ->
    (check bool) "not error" false is_error;
    (check string) "null result" "null" (Yojson.Basic.to_string result)
  | _ -> fail "expected tool result with null output"

let test_parse_tool_missing_fields_skipped () =
  (* Tool invocation without required fields should be skipped *)
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-search","state":"output-available"}
          ]}]}|})
  in
  (check int) "no messages (incomplete tool skipped)" 0 (List.length msgs)

let test_parse_tool_error_without_error_text () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"tool-search","toolCallId":"tc_x","toolName":"search",
             "state":"output-error","input":{"q":"test"}}
          ]}]}|})
  in
  match msgs with
  | [ Assistant _; Tool { content = [ { result; _ } ] } ] ->
    (check string) "default error" {|"Tool execution failed"|} (Yojson.Basic.to_string result)
  | _ -> fail "expected default error text"

let test_parse_assistant_file () =
  let msgs =
    parse
      (json
         {|{"messages":[{"role":"assistant","parts":[
            {"type":"file","mediaType":"image/png","url":"https://example.com/gen.png","filename":"generated.png"}
          ]}]}|})
  in
  match msgs with
  | [ Assistant { content = [ File { data = Url url; media_type; filename; _ } ] } ] ->
    (check string) "url" "https://example.com/gen.png" url;
    (check string) "media_type" "image/png" media_type;
    (check (option string)) "filename" (Some "generated.png") filename
  | _ -> fail "expected Assistant with File part"

let test_parse_no_messages_field () =
  let msgs = parse (json {|{"other":"field"}|}) in
  (check int) "empty" 0 (List.length msgs)

let test_parse_text_part_missing_text_skipped () =
  let msgs = parse (json {|{"messages":[{"role":"user","parts":[
            {"type":"text"}
          ]}]}|}) in
  (check int) "no messages (text without text field)" 0 (List.length msgs)

let test_parse_extra_request_fields_ignored () =
  (* v6 sends id, messageId, trigger — these should be ignored *)
  let msgs =
    parse
      (json
         {|{"id":"chat_1","messageId":"m_1","trigger":"submit-message",
            "messages":[{"role":"user","parts":[{"type":"text","text":"Hi"}]}]}|})
  in
  match msgs with
  | [ User { content = [ Text { text; _ } ] } ] -> (check string) "text" "Hi" text
  | _ -> fail "expected User message (extra fields ignored)"

let test_collect_approved_ids () =
  let json =
    Yojson.Basic.from_string
      {|{
    "messages": [{
      "role": "assistant",
      "parts": [
        {
          "type": "tool-weather",
          "toolCallId": "tc_1",
          "toolName": "weather",
          "state": "approval-responded",
          "approved": true,
          "input": {"city": "London"}
        },
        {
          "type": "tool-deploy",
          "toolCallId": "tc_2",
          "toolName": "deploy",
          "state": "approval-responded",
          "approved": false,
          "input": {}
        }
      ]
    }]
  }|}
  in
  let ids = Ai_core.Server_handler.collect_approved_tool_call_ids json in
  (check int) "1 approved" 1 (List.length ids);
  match ids with
  | id :: _ -> (check string) "tc_1" "tc_1" id
  | [] -> Alcotest.fail "expected at least one approved id"

let test_collect_approved_ids_empty () =
  let json = Yojson.Basic.from_string {|{"messages": [{"role": "user", "parts": [{"type": "text", "text": "Hi"}]}]}|} in
  let ids = Ai_core.Server_handler.collect_approved_tool_call_ids json in
  (check int) "0 approved" 0 (List.length ids)

let test_collect_approved_ids_invalid_json () =
  let json = `String "not an object" in
  let ids = Ai_core.Server_handler.collect_approved_tool_call_ids json in
  (check int) "0 on invalid" 0 (List.length ids)

let () =
  run "Server_handler"
    [
      ( "make_sse_response",
        [
          test_case "basic" `Quick test_make_sse_response_basic;
          test_case "all_headers" `Quick test_make_sse_response_all_headers;
          test_case "extra_headers" `Quick test_make_sse_response_extra_headers;
          test_case "custom_status" `Quick test_make_sse_response_custom_status;
          test_case "body_content" `Quick test_make_sse_response_body_content;
        ] );
      ( "parse_messages: basic",
        [
          test_case "user text only" `Quick test_parse_user_text_only;
          test_case "user multiple text parts" `Quick test_parse_user_multiple_text_parts;
          test_case "system message" `Quick test_parse_system_message;
          test_case "system concatenates text" `Quick test_parse_system_concatenates_text_parts;
          test_case "assistant text" `Quick test_parse_assistant_text;
          test_case "assistant reasoning + text" `Quick test_parse_assistant_reasoning;
          test_case "multi-turn conversation" `Quick test_parse_multi_turn_conversation;
        ] );
      ( "parse_messages: files",
        [
          test_case "user file url" `Quick test_parse_user_file_url;
          test_case "user file base64" `Quick test_parse_user_file_base64;
          test_case "user text + file" `Quick test_parse_user_text_and_file;
          test_case "assistant file" `Quick test_parse_assistant_file;
          test_case "file missing mediaType" `Quick test_parse_file_missing_media_type_skipped;
          test_case "file missing data+url" `Quick test_parse_file_missing_data_and_url_skipped;
        ] );
      ( "parse_messages: tool invocations",
        [
          test_case "output-available" `Quick test_parse_tool_invocation_output_available;
          test_case "output-error" `Quick test_parse_tool_invocation_output_error;
          test_case "output-denied" `Quick test_parse_tool_invocation_output_denied;
          test_case "input-available (no result)" `Quick test_parse_tool_invocation_input_available;
          test_case "dynamic-tool" `Quick test_parse_dynamic_tool;
          test_case "multiple tool calls" `Quick test_parse_multiple_tool_calls;
          test_case "input-streaming (no result)" `Quick test_parse_tool_invocation_input_streaming;
          test_case "approval-requested (no result)" `Quick test_parse_tool_approval_requested;
          test_case "approval-responded approved (no result)" `Quick test_parse_tool_approval_responded_approved;
          test_case "approval-responded denied (error result)" `Quick test_parse_tool_approval_responded_denied;
          test_case "output-available null output" `Quick test_parse_tool_output_available_null_output;
          test_case "tool missing fields" `Quick test_parse_tool_missing_fields_skipped;
          test_case "tool error no errorText" `Quick test_parse_tool_error_without_error_text;
        ] );
      ( "collect_approved_tool_call_ids",
        [
          test_case "approved ids" `Quick test_collect_approved_ids;
          test_case "no approved ids" `Quick test_collect_approved_ids_empty;
          test_case "invalid json" `Quick test_collect_approved_ids_invalid_json;
        ] );
      ( "parse_messages: edge cases",
        [
          test_case "unknown parts skipped" `Quick test_parse_skip_unknown_parts;
          test_case "step-start skipped" `Quick test_parse_skip_step_start;
          test_case "empty parts" `Quick test_parse_empty_parts;
          test_case "missing parts field" `Quick test_parse_missing_parts;
          test_case "unknown role skipped" `Quick test_parse_unknown_role_skipped;
          test_case "invalid json" `Quick test_parse_invalid_json_returns_empty;
          test_case "no messages field" `Quick test_parse_no_messages_field;
          test_case "text part missing text" `Quick test_parse_text_part_missing_text_skipped;
          test_case "extra request fields" `Quick test_parse_extra_request_fields_ignored;
        ] );
    ]
