(* Helper: create a mock streaming model that emits text *)
let make_mock_stream_model () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock"

    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      push (Some (Ai_provider.Stream_part.Text { text = "Hello " }));
      push (Some (Ai_provider.Stream_part.Text { text = "world!" }));
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Stop; usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

(* Helper: create a mock model that emits reasoning *)
let make_reasoning_stream_model () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock"

    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      push (Some (Ai_provider.Stream_part.Reasoning { text = "thinking..." }));
      push (Some (Ai_provider.Stream_part.Text { text = "Answer" }));
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Stop; usage = { input_tokens = 5; output_tokens = 3; total_tokens = Some 8 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let test_text_to_ui_chunks () =
  let model = make_mock_stream_model () in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" () in
  let ui_chunks =
    Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream ~message_id:"msg_1" result))
  in
  (* Should have: Start, Start_step, Text_start, Text_delta x2, Text_end, Finish_step, Finish *)
  let has_start =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Start { message_id = Some "msg_1"; _ } -> true
        | _ -> false)
      ui_chunks
  in
  Alcotest.(check bool) "has Start with msg_id" true has_start;
  let text_deltas =
    List.filter_map
      (function
        | Ai_core.Ui_message_chunk.Text_delta { delta; _ } -> Some delta
        | _ -> None)
      ui_chunks
  in
  Alcotest.(check string) "combined text" "Hello world!" (String.concat "" text_deltas);
  let has_finish =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Finish _ -> true
        | _ -> false)
      ui_chunks
  in
  Alcotest.(check bool) "has Finish" true has_finish

let test_sse_output () =
  let model = make_mock_stream_model () in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" () in
  let sse_lines =
    Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_sse_stream ~message_id:"msg_1" result))
  in
  (* Each line should start with "data: " *)
  List.iter
    (fun line ->
      Alcotest.(check bool) "starts with data:" true (String.length line >= 6 && String.sub line 0 6 = "data: "))
    sse_lines;
  (* Last should be [DONE] *)
  let last = List.nth sse_lines (List.length sse_lines - 1) in
  Alcotest.(check string) "ends with DONE" "data: [DONE]\n\n" last

let test_reasoning_filtered () =
  let model = make_reasoning_stream_model () in
  (* With reasoning disabled *)
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Test" () in
  let ui_chunks =
    Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream ~send_reasoning:false result))
  in
  let has_reasoning =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Reasoning_delta _ -> true
        | _ -> false)
      ui_chunks
  in
  Alcotest.(check bool) "no reasoning when disabled" false has_reasoning;
  (* Text should still be present *)
  let has_text =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Text_delta _ -> true
        | _ -> false)
      ui_chunks
  in
  Alcotest.(check bool) "text still present" true has_text

let test_reasoning_included () =
  let model = make_reasoning_stream_model () in
  (* With reasoning enabled (default) *)
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Test" () in
  let ui_chunks = Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream result)) in
  let has_reasoning =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Reasoning_delta _ -> true
        | _ -> false)
      ui_chunks
  in
  Alcotest.(check bool) "reasoning present when enabled" true has_reasoning

let () =
  Alcotest.run "To_ui_stream"
    [
      ( "transform",
        [
          Alcotest.test_case "text_chunks" `Quick test_text_to_ui_chunks;
          Alcotest.test_case "sse_output" `Quick test_sse_output;
          Alcotest.test_case "reasoning_filtered" `Quick test_reasoning_filtered;
          Alcotest.test_case "reasoning_included" `Quick test_reasoning_included;
        ] );
    ]
