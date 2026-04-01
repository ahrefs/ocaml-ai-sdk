open Alcotest

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
  (check bool) "has Start with msg_id" true has_start;
  let text_deltas =
    List.filter_map
      (function
        | Ai_core.Ui_message_chunk.Text_delta { delta; _ } -> Some delta
        | _ -> None)
      ui_chunks
  in
  (check string) "combined text" "Hello world!" (String.concat "" text_deltas);
  let has_finish =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Finish _ -> true
        | _ -> false)
      ui_chunks
  in
  (check bool) "has Finish" true has_finish

let test_sse_output () =
  let model = make_mock_stream_model () in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" () in
  let sse_lines =
    Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_sse_stream ~message_id:"msg_1" result))
  in
  (* Each line should start with "data: " *)
  List.iter
    (fun line -> (check bool) "starts with data:" true (String.length line >= 6 && String.sub line 0 6 = "data: "))
    sse_lines;
  (* Last should be [DONE] *)
  let last = List.nth sse_lines (List.length sse_lines - 1) in
  (check string) "ends with DONE" "data: [DONE]\n\n" last

let is_reasoning_chunk = function
  | Ai_core.Ui_message_chunk.Reasoning_start _ | Reasoning_delta _ | Reasoning_end _ -> true
  | _ -> false

let test_reasoning_filtered () =
  let model = make_reasoning_stream_model () in
  (* With reasoning disabled *)
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Test" () in
  let ui_chunks =
    Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream ~send_reasoning:false result))
  in
  let reasoning_chunks = List.filter is_reasoning_chunk ui_chunks in
  (check int) "no reasoning chunks when disabled" 0 (List.length reasoning_chunks);
  (* Text should still be present *)
  let has_text =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Text_delta _ -> true
        | _ -> false)
      ui_chunks
  in
  (check bool) "text still present" true has_text

let test_reasoning_included () =
  let model = make_reasoning_stream_model () in
  (* With reasoning enabled (default) *)
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Test" () in
  let ui_chunks = Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream result)) in
  let reasoning_chunks = List.filter is_reasoning_chunk ui_chunks in
  (* Should have Reasoning_start + Reasoning_delta + Reasoning_end *)
  (check bool) "reasoning chunks present when enabled" true (List.length reasoning_chunks >= 3);
  let has_start =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Reasoning_start _ -> true
        | _ -> false)
      ui_chunks
  in
  let has_delta =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Reasoning_delta _ -> true
        | _ -> false)
      ui_chunks
  in
  let has_end =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Reasoning_end _ -> true
        | _ -> false)
      ui_chunks
  in
  (check bool) "has reasoning_start" true has_start;
  (check bool) "has reasoning_delta" true has_delta;
  (check bool) "has reasoning_end" true has_end

let test_tool_approval_request () =
  (* Build a full_stream with Tool_call_delta, Tool_call, then Tool_approval_request *)
  let full_stream, push_full = Lwt_stream.create () in
  let tool_call_id = "tc_1" in
  let tool_name = "dangerous_tool" in
  let args = `Assoc [ "key", `String "value" ] in
  List.iter
    (fun p -> push_full (Some p))
    Ai_core.Text_stream_part.
      [
        Start;
        Start_step;
        Tool_call_delta { tool_call_id; tool_name; args_text_delta = "{\"key\":" };
        Tool_call_delta { tool_call_id; tool_name; args_text_delta = "\"value\"}" };
        Tool_approval_request { approval_id = "appr_1"; tool_call_id; tool_name; args };
        Finish_step { finish_reason = Stop; usage = { input_tokens = 5; output_tokens = 3; total_tokens = Some 8 } };
        Finish { finish_reason = Stop; usage = { input_tokens = 5; output_tokens = 3; total_tokens = Some 8 } };
      ];
  push_full None;
  let result : Ai_core.Stream_text_result.t =
    {
      text_stream = Lwt_stream.of_list [];
      full_stream;
      partial_output_stream = Lwt_stream.of_list [];
      usage = Lwt.return { Ai_provider.Usage.input_tokens = 5; output_tokens = 3; total_tokens = Some 8 };
      finish_reason = Lwt.return Ai_provider.Finish_reason.Stop;
      steps = Lwt.return [];
      warnings = [];
      output = Lwt.return_none;
    }
  in
  let ui_chunks =
    Lwt_main.run
      (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream ~message_id:"msg_approval" result))
  in
  (* Should have Tool_input_start *)
  let has_tool_input_start =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Tool_input_start { tool_call_id = id; tool_name = name } ->
          String.equal id "tc_1" && String.equal name "dangerous_tool"
        | _ -> false)
      ui_chunks
  in
  (check bool) "has Tool_input_start" true has_tool_input_start;
  (* Should have Tool_input_available *)
  let has_tool_input_available =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Tool_input_available { tool_call_id = id; tool_name = name; _ } ->
          String.equal id "tc_1" && String.equal name "dangerous_tool"
        | _ -> false)
      ui_chunks
  in
  (check bool) "has Tool_input_available" true has_tool_input_available;
  (* Should have Tool_approval_request *)
  let has_tool_approval_request =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Tool_approval_request { approval_id = aid; tool_call_id = id } ->
          String.equal id "tc_1" && String.equal aid "appr_1"
        | _ -> false)
      ui_chunks
  in
  (check bool) "has Tool_approval_request" true has_tool_approval_request;
  (* Should NOT have Tool_output_available or Tool_output_error *)
  let has_tool_output =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Tool_output_available _ | Tool_output_error _ -> true
        | _ -> false)
      ui_chunks
  in
  (check bool) "no Tool_output chunks" false has_tool_output

let test_tool_output_denied () =
  let full_stream, push_full = Lwt_stream.create () in
  List.iter
    (fun p -> push_full (Some p))
    Ai_core.Text_stream_part.
      [
        Start;
        Start_step;
        Tool_call { tool_call_id = "tc_1"; tool_name = "dangerous"; args = `Assoc [ "key", `String "val" ] };
        Tool_output_denied { tool_call_id = "tc_1" };
        Finish_step { finish_reason = Stop; usage = { input_tokens = 5; output_tokens = 3; total_tokens = Some 8 } };
        Finish { finish_reason = Stop; usage = { input_tokens = 5; output_tokens = 3; total_tokens = Some 8 } };
      ];
  push_full None;
  let result : Ai_core.Stream_text_result.t =
    {
      text_stream = Lwt_stream.of_list [];
      full_stream;
      partial_output_stream = Lwt_stream.of_list [];
      usage = Lwt.return { Ai_provider.Usage.input_tokens = 5; output_tokens = 3; total_tokens = Some 8 };
      finish_reason = Lwt.return Ai_provider.Finish_reason.Stop;
      steps = Lwt.return [];
      warnings = [];
      output = Lwt.return_none;
    }
  in
  let ui_chunks =
    Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream ~message_id:"msg_denied" result))
  in
  let has_denied =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Tool_output_denied { tool_call_id } -> String.equal tool_call_id "tc_1"
        | _ -> false)
      ui_chunks
  in
  (check bool) "has Tool_output_denied" true has_denied;
  (* Should NOT have Tool_output_error *)
  let has_error =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Tool_output_error _ -> true
        | _ -> false)
      ui_chunks
  in
  (check bool) "no Tool_output_error" false has_error

let () =
  run "To_ui_stream"
    [
      ( "transform",
        [
          test_case "text_chunks" `Quick test_text_to_ui_chunks;
          test_case "sse_output" `Quick test_sse_output;
          test_case "reasoning_filtered" `Quick test_reasoning_filtered;
          test_case "reasoning_included" `Quick test_reasoning_included;
          test_case "tool_approval_request" `Quick test_tool_approval_request;
          test_case "tool_output_denied" `Quick test_tool_output_denied;
        ] );
    ]
