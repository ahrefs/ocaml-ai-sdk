open Alcotest

let make_event_stream events =
  let stream, push = Lwt_stream.create () in
  List.iter (fun evt -> push (Some evt)) events;
  push None;
  stream

let make_sse ~event_type ~data : Ai_provider_anthropic.Sse.event = { event_type; data }

let test_text_streaming () =
  let events =
    make_event_stream
      [
        make_sse ~event_type:"message_start"
          ~data:{|{"id":"msg_1","model":"claude","usage":{"input_tokens":10,"output_tokens":0}}|};
        make_sse ~event_type:"content_block_start" ~data:{|{"index":0,"content_block":{"type":"text","text":""}}|};
        make_sse ~event_type:"content_block_delta" ~data:{|{"index":0,"delta":{"type":"text_delta","text":"Hello"}}|};
        make_sse ~event_type:"content_block_delta" ~data:{|{"index":0,"delta":{"type":"text_delta","text":" world"}}|};
        make_sse ~event_type:"content_block_stop" ~data:{|{"index":0}|};
        make_sse ~event_type:"message_delta" ~data:{|{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}|};
        make_sse ~event_type:"message_stop" ~data:{|{}|};
      ]
  in
  let parts = Lwt_main.run (Lwt_stream.to_list (Ai_provider_anthropic.Convert_stream.transform events ~warnings:[])) in
  (* Should have: Stream_start, Text "Hello", Text " world", Finish *)
  (check int) "4 parts" 4 (List.length parts);
  match parts with
  | Ai_provider.Stream_part.Stream_start _
    :: Text { text = t1 }
    :: Text { text = t2 }
    :: Finish { finish_reason; _ }
    :: _ ->
    (check string) "text 1" "Hello" t1;
    (check string) "text 2" " world" t2;
    (check string) "finish" "stop" (Ai_provider.Finish_reason.to_string finish_reason)
  | _ -> fail "unexpected stream parts"

let test_tool_call_streaming () =
  let events =
    make_event_stream
      [
        make_sse ~event_type:"message_start"
          ~data:{|{"id":"msg_2","model":"claude","usage":{"input_tokens":10,"output_tokens":0}}|};
        make_sse ~event_type:"content_block_start"
          ~data:{|{"index":0,"content_block":{"type":"tool_use","id":"tc_1","name":"search"}}|};
        make_sse ~event_type:"content_block_delta"
          ~data:{|{"index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}|};
        make_sse ~event_type:"content_block_delta"
          ~data:{|{"index":0,"delta":{"type":"input_json_delta","partial_json":"\"test\"}"}}|};
        make_sse ~event_type:"content_block_stop" ~data:{|{"index":0}|};
        make_sse ~event_type:"message_delta" ~data:{|{"delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":10}}|};
      ]
  in
  let parts = Lwt_main.run (Lwt_stream.to_list (Ai_provider_anthropic.Convert_stream.transform events ~warnings:[])) in
  (* Stream_start, Tool_call_delta x2, Tool_call_finish, Finish *)
  (check int) "5 parts" 5 (List.length parts);
  match parts with
  | _ :: Tool_call_delta { tool_name; tool_call_id; _ } :: _ :: Tool_call_finish { tool_call_id = finish_id } :: _ ->
    (check string) "tool name" "search" tool_name;
    (check string) "tool id" "tc_1" tool_call_id;
    (check string) "finish id" "tc_1" finish_id
  | _ -> fail "unexpected stream parts"

let test_thinking_streaming () =
  let events =
    make_event_stream
      [
        make_sse ~event_type:"message_start"
          ~data:{|{"id":"msg_3","model":"claude","usage":{"input_tokens":10,"output_tokens":0}}|};
        make_sse ~event_type:"content_block_start" ~data:{|{"index":0,"content_block":{"type":"thinking"}}|};
        make_sse ~event_type:"content_block_delta"
          ~data:{|{"index":0,"delta":{"type":"thinking_delta","thinking":"Let me think..."}}|};
        make_sse ~event_type:"content_block_stop" ~data:{|{"index":0}|};
        make_sse ~event_type:"content_block_start" ~data:{|{"index":1,"content_block":{"type":"text","text":""}}|};
        make_sse ~event_type:"content_block_delta" ~data:{|{"index":1,"delta":{"type":"text_delta","text":"Answer"}}|};
        make_sse ~event_type:"content_block_stop" ~data:{|{"index":1}|};
        make_sse ~event_type:"message_delta" ~data:{|{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":20}}|};
      ]
  in
  let parts = Lwt_main.run (Lwt_stream.to_list (Ai_provider_anthropic.Convert_stream.transform events ~warnings:[])) in
  (* Stream_start, Reasoning, Text, Finish *)
  (check int) "4 parts" 4 (List.length parts);
  match parts with
  | _ :: Reasoning { text } :: _ -> (check string) "thinking" "Let me think..." text
  | _ -> fail "expected Reasoning"

let test_malformed_event_emits_error () =
  let events =
    make_event_stream
      [
        make_sse ~event_type:"message_start"
          ~data:{|{"id":"msg_4","model":"claude","usage":{"input_tokens":1,"output_tokens":0}}|};
        make_sse ~event_type:"content_block_start" ~data:{|not valid json at all|};
      ]
  in
  let parts = Lwt_main.run (Lwt_stream.to_list (Ai_provider_anthropic.Convert_stream.transform events ~warnings:[])) in
  let has_error =
    List.exists
      (function
        | Ai_provider.Stream_part.Error _ -> true
        | _ -> false)
      parts
  in
  (check bool) "has error" true has_error

let () =
  run "Convert_stream"
    [
      ( "transform",
        [
          test_case "text" `Quick test_text_streaming;
          test_case "tool_call" `Quick test_tool_call_streaming;
          test_case "thinking" `Quick test_thinking_streaming;
          test_case "malformed_event" `Quick test_malformed_event_emits_error;
        ] );
    ]
