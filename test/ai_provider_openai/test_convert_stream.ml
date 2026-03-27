open Alcotest

let make_sse_event data = { Ai_provider_openai.Sse.event_type = ""; data }

let test_stream_text () =
  let events, push = Lwt_stream.create () in
  push (Some (make_sse_event {|{"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}|}));
  push (Some (make_sse_event {|{"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}|}));
  push
    (Some
       (make_sse_event
          {|{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}|}));
  push (Some (make_sse_event "[DONE]"));
  push None;
  let parts = Ai_provider_openai.Convert_stream.transform events ~warnings:[] in
  let result = Lwt_main.run (Lwt_stream.to_list parts) in
  (* Stream_start, Text "Hello", Text " world", Finish (exactly one — [DONE] deduped) *)
  let finish_count =
    List.length
      (List.filter
         (function
           | Ai_provider.Stream_part.Finish _ -> true
           | _ -> false)
         result)
  in
  (check int) "exactly one Finish" 1 finish_count;
  let texts =
    List.filter_map
      (function
        | Ai_provider.Stream_part.Text { text } -> Some text
        | _ -> None)
      result
  in
  (check int) "text parts" 2 (List.length texts);
  (check string) "first" "Hello" (List.nth texts 0);
  (check string) "second" " world" (List.nth texts 1);
  let has_start =
    List.exists
      (function
        | Ai_provider.Stream_part.Stream_start _ -> true
        | _ -> false)
      result
  in
  (check bool) "has start" true has_start

let test_stream_tool_calls () =
  let events, push = Lwt_stream.create () in
  (* First chunk: tool call start with id and name *)
  push
    (Some
       (make_sse_event
          {|{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}|}));
  (* Second chunk: arguments fragment *)
  push
    (Some
       (make_sse_event
          {|{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]},"finish_reason":null}]}|}));
  (* Third chunk: more arguments *)
  push
    (Some
       (make_sse_event
          {|{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"NYC\"}"}}]},"finish_reason":null}]}|}));
  (* Finish *)
  push
    (Some
       (make_sse_event
          {|{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":8}}|}));
  push (Some (make_sse_event "[DONE]"));
  push None;
  let parts = Ai_provider_openai.Convert_stream.transform events ~warnings:[] in
  let result = Lwt_main.run (Lwt_stream.to_list parts) in
  let tool_deltas =
    List.filter_map
      (function
        | Ai_provider.Stream_part.Tool_call_delta { tool_name; args_text_delta; _ } -> Some (tool_name, args_text_delta)
        | _ -> None)
      result
  in
  (check int) "tool deltas" 2 (List.length tool_deltas);
  let _name, first_args = List.nth tool_deltas 0 in
  (check string) "first args" {|{"city":|} first_args;
  let has_finish =
    List.exists
      (function
        | Ai_provider.Stream_part.Tool_call_finish _ -> true
        | _ -> false)
      result
  in
  (check bool) "has tool_call_finish" true has_finish

let test_stream_error () =
  let events, push = Lwt_stream.create () in
  push (Some (make_sse_event "not valid json {{{"));
  push (Some (make_sse_event "[DONE]"));
  push None;
  let parts = Ai_provider_openai.Convert_stream.transform events ~warnings:[] in
  let result = Lwt_main.run (Lwt_stream.to_list parts) in
  let has_error =
    List.exists
      (function
        | Ai_provider.Stream_part.Error _ -> true
        | _ -> false)
      result
  in
  (check bool) "has error" true has_error

let () =
  run "Convert_stream"
    [
      ( "transform",
        [
          test_case "text" `Quick test_stream_text;
          test_case "tool_calls" `Quick test_stream_tool_calls;
          test_case "error" `Quick test_stream_error;
        ] );
    ]
