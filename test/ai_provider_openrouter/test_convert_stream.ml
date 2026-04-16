open Alcotest

let collect_stream stream =
  let parts = ref [] in
  Lwt_main.run (Lwt_stream.iter (fun part -> parts := part :: !parts) stream);
  List.rev !parts

let make_sse_event data = { Ai_provider_openrouter.Sse.event_type = ""; data }

let test_basic_text_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event {|{"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}|};
        make_sse_event {|{"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  match parts with
  | [ Stream_start _; Text { text = t1 }; Text { text = t2 }; Finish { finish_reason; _ } ] ->
    (check string) "text1" "Hello" t1;
    (check string) "text2" " world" t2;
    (check string) "finish" "stop" (Ai_provider.Finish_reason.to_string finish_reason)
  | _ -> fail "expected [Stream_start; Text; Text; Finish]"

let test_reasoning_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event {|{"choices":[{"index":0,"delta":{"reasoning":"Let me think..."},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":"The answer is 42."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  match parts with
  | [ Stream_start _; Reasoning { text = r }; Text { text = t }; Finish _ ] ->
    (check string) "reasoning" "Let me think..." r;
    (check string) "text" "The answer is 42." t
  | _ -> fail "expected [Stream_start; Reasoning; Text; Finish]"

let test_tool_call_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"London\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":15,"completion_tokens":10}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  (* Stream_start, Tool_call_delta x2, Tool_call_finish, Finish *)
  let tool_deltas =
    List.filter
      (function
        | Ai_provider.Stream_part.Tool_call_delta _ -> true
        | _ -> false)
      parts
  in
  (check int) "tool call deltas" 2 (List.length tool_deltas);
  let finishes =
    List.filter
      (function
        | Ai_provider.Stream_part.Tool_call_finish _ -> true
        | _ -> false)
      parts
  in
  (check int) "tool call finishes" 1 (List.length finishes)

let test_done_signal () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event {|{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}|};
        make_sse_event "[DONE]";
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  let finish_parts =
    List.filter
      (function
        | Ai_provider.Stream_part.Finish _ -> true
        | _ -> false)
      parts
  in
  (check int) "one finish" 1 (List.length finish_parts)

let test_reasoning_details_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.text","text":"Thinking..."}]},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":"Answer."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  match parts with
  | [ Stream_start _; Reasoning { text = r }; Text { text = t }; Finish _ ] ->
    (check string) "reasoning" "Thinking..." r;
    (check string) "text" "Answer." t
  | _ -> fail "expected [Stream_start; Reasoning; Text; Finish]"

let test_encrypted_reasoning_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.encrypted","data":"abc123"}]},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":"Result."},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  (* Encrypted reasoning is skipped in visible stream parts (matches upstream).
     Only Stream_start, Text, and Finish should appear. *)
  let reasoning_parts =
    List.filter
      (function
        | Ai_provider.Stream_part.Reasoning _ -> true
        | _ -> false)
      parts
  in
  (check int) "no reasoning parts" 0 (List.length reasoning_parts);
  let text_parts =
    List.filter
      (function
        | Ai_provider.Stream_part.Text _ -> true
        | _ -> false)
      parts
  in
  (check int) "one text part" 1 (List.length text_parts)

let test_summary_reasoning_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.summary","summary":"Brief summary"}]},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":"Done."},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  let reasoning_parts =
    List.filter
      (function
        | Ai_provider.Stream_part.Reasoning _ -> true
        | _ -> false)
      parts
  in
  (check int) "one reasoning part" 1 (List.length reasoning_parts);
  match reasoning_parts with
  | [ Reasoning { text } ] -> (check string) "summary" "Brief summary" text
  | _ -> fail "expected Reasoning with summary"

let test_error_chunk_stream () =
  let events = Lwt_stream.of_list [ make_sse_event {|{"error":{"message":"Rate limit exceeded","code":429}}|} ] in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  let error_parts =
    List.filter
      (function
        | Ai_provider.Stream_part.Error _ -> true
        | _ -> false)
      parts
  in
  (check int) "one error" 1 (List.length error_parts);
  let finish_parts =
    List.filter
      (function
        | Ai_provider.Stream_part.Finish _ -> true
        | _ -> false)
      parts
  in
  (check int) "one finish" 1 (List.length finish_parts);
  match finish_parts with
  | [ Finish { finish_reason; _ } ] ->
    (check string) "error finish" "error" (Ai_provider.Finish_reason.to_string finish_reason)
  | _ -> fail "expected Finish with error reason"

let test_finish_reason_override_encrypted_tool_calls_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.encrypted","data":"enc123"}]},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search","arguments":"{}"}}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  let finish_parts =
    List.filter
      (function
        | Ai_provider.Stream_part.Finish _ -> true
        | _ -> false)
      parts
  in
  (check int) "one finish" 1 (List.length finish_parts);
  match finish_parts with
  | [ Finish { finish_reason; _ } ] ->
    (check string) "overridden to tool_calls" "tool-calls" (Ai_provider.Finish_reason.to_string finish_reason)
  | _ -> fail "expected Finish with tool_calls reason"

let test_accumulated_finish_reason_on_done () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"length"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}|};
        make_sse_event "[DONE]";
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  let finish_parts =
    List.filter
      (function
        | Ai_provider.Stream_part.Finish _ -> true
        | _ -> false)
      parts
  in
  (* Only one finish — the chunk's finish_reason is used, [DONE] doesn't duplicate *)
  (check int) "one finish" 1 (List.length finish_parts);
  match finish_parts with
  | [ Finish { finish_reason; _ } ] ->
    (check string) "length reason" "length" (Ai_provider.Finish_reason.to_string finish_reason)
  | _ -> fail "expected Finish with length reason"

let test_annotations_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":"See sources.","annotations":[{"type":"url_citation","url":"https://example.com","title":"Example"}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  let source_parts =
    List.filter
      (function
        | Ai_provider.Stream_part.Source _ -> true
        | _ -> false)
      parts
  in
  (check int) "one source" 1 (List.length source_parts);
  match source_parts with
  | [ Source { url; title; source_type; _ } ] ->
    (check string) "source_type" "url" source_type;
    (check string) "url" "https://example.com" url;
    (check (option string)) "title" (Some "Example") title
  | _ -> fail "expected one Source part"

let () =
  run "Convert_stream"
    [
      ( "convert_stream",
        [
          test_case "basic_text" `Quick test_basic_text_stream;
          test_case "reasoning" `Quick test_reasoning_stream;
          test_case "tool_calls" `Quick test_tool_call_stream;
          test_case "done_signal" `Quick test_done_signal;
          test_case "reasoning_details" `Quick test_reasoning_details_stream;
          test_case "encrypted_reasoning" `Quick test_encrypted_reasoning_stream;
          test_case "summary_reasoning" `Quick test_summary_reasoning_stream;
          test_case "error_chunk" `Quick test_error_chunk_stream;
          test_case "finish_override_encrypted_tools" `Quick test_finish_reason_override_encrypted_tool_calls_stream;
          test_case "accumulated_finish_reason" `Quick test_accumulated_finish_reason_on_done;
          test_case "annotations" `Quick test_annotations_stream;
        ] );
    ]
