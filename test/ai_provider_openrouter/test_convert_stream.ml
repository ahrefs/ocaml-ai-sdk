open Alcotest

let collect_stream stream =
  let parts = ref [] in
  Lwt_main.run
    (Lwt_stream.iter (fun part -> parts := part :: !parts) stream);
  List.rev !parts

let make_sse_event data = { Ai_provider_openrouter.Sse.event_type = ""; data }

let test_basic_text_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  (match parts with
  | [ Stream_start _; Text { text = t1 }; Text { text = t2 }; Finish { finish_reason; _ } ] ->
    (check string) "text1" "Hello" t1;
    (check string) "text2" " world" t2;
    (check string) "finish" "stop" (Ai_provider.Finish_reason.to_string finish_reason)
  | _ -> fail "expected [Stream_start; Text; Text; Finish]")

let test_reasoning_stream () =
  let events =
    Lwt_stream.of_list
      [
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"reasoning":"Let me think..."},"finish_reason":null}]}|};
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":"The answer is 42."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}|};
      ]
  in
  let stream = Ai_provider_openrouter.Convert_stream.transform events ~warnings:[] in
  let parts = collect_stream stream in
  (match parts with
  | [ Stream_start _; Reasoning { text = r }; Text { text = t }; Finish _ ] ->
    (check string) "reasoning" "Let me think..." r;
    (check string) "text" "The answer is 42." t
  | _ -> fail "expected [Stream_start; Reasoning; Text; Finish]")

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
        make_sse_event
          {|{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}|};
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

let () =
  run "Convert_stream"
    [
      ( "convert_stream",
        [
          test_case "basic_text" `Quick test_basic_text_stream;
          test_case "reasoning" `Quick test_reasoning_stream;
          test_case "tool_calls" `Quick test_tool_call_stream;
          test_case "done_signal" `Quick test_done_signal;
        ] );
    ]
