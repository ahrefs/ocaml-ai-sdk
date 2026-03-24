(** End-to-end tests for the Core SDK.

    Tests the full pipeline from generate_text/stream_text through
    to UIMessage stream output, using mock Anthropic provider responses.

    Note: The Anthropic provider's mock fetch always returns JSON (non-streaming),
    so generate_text tests go through the real Anthropic provider with mock fetch,
    while stream_text tests use mock Language_model.S modules that still exercise
    the complete stream_text -> to_ui_message_stream pipeline. *)

(* === Mock Anthropic Provider Responses === *)

(* Simple text response *)
let mock_text_response =
  Yojson.Safe.from_string
    {|{
      "id": "msg_e2e_1",
      "content": [{"type": "text", "text": "The capital of France is Paris."}],
      "model": "claude-sonnet-4-6",
      "stop_reason": "end_turn",
      "usage": {"input_tokens": 15, "output_tokens": 8}
    }|}

(* Tool call response *)
let mock_tool_call_response =
  Yojson.Safe.from_string
    {|{
      "id": "msg_e2e_2",
      "content": [
        {"type": "text", "text": "Let me look that up."},
        {"type": "tool_use", "id": "toolu_1", "name": "get_weather",
         "input": {"city": "Paris"}}
      ],
      "model": "claude-sonnet-4-6",
      "stop_reason": "tool_use",
      "usage": {"input_tokens": 20, "output_tokens": 15}
    }|}

(* Follow-up text after tool *)
let mock_followup_response =
  Yojson.Safe.from_string
    {|{
      "id": "msg_e2e_3",
      "content": [{"type": "text", "text": "The weather in Paris is 22C and sunny."}],
      "model": "claude-sonnet-4-6",
      "stop_reason": "end_turn",
      "usage": {"input_tokens": 30, "output_tokens": 12}
    }|}

(* Thinking response *)
let mock_thinking_response =
  Yojson.Safe.from_string
    {|{
      "id": "msg_e2e_4",
      "content": [
        {"type": "thinking", "thinking": "Let me count the r's...", "signature": "sig_1"},
        {"type": "text", "text": "There are 3 r's in strawberry."}
      ],
      "model": "claude-sonnet-4-6",
      "stop_reason": "end_turn",
      "usage": {"input_tokens": 25, "output_tokens": 20}
    }|}

let make_mock_config response =
  let fetch ~url:_ ~headers:_ ~body:_ = Lwt.return response in
  Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch ()

(* Tool-loop mock: returns tool call first, then text *)
let make_tool_loop_config () =
  let call_count = ref 0 in
  let fetch ~url:_ ~headers:_ ~body:_ =
    incr call_count;
    if !call_count = 1 then Lwt.return mock_tool_call_response else Lwt.return mock_followup_response
  in
  Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch ()

let weather_tool : Ai_core.Core_tool.t =
  {
    description = Some "Get weather for a city";
    parameters =
      `Assoc [ "type", `String "object"; "properties", `Assoc [ "city", `Assoc [ "type", `String "string" ] ] ];
    execute =
      (fun args ->
        let city = try Yojson.Safe.Util.(member "city" args |> to_string) with _ -> "unknown" in
        Lwt.return (`Assoc [ "city", `String city; "temperature", `Int 22; "condition", `String "sunny" ]));
  }

(* === Mock Language_model for streaming tests === *)

(* Mock streaming model that emits text character by character *)
let make_stream_model response_text =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock-anthropic"
    let model_id = "claude-sonnet-4-6"

    let generate _opts =
      Lwt.return
        {
          Ai_provider.Generate_result.content = [ Ai_provider.Content.Text { text = response_text } ];
          finish_reason = Stop;
          usage = { input_tokens = 15; output_tokens = 8; total_tokens = Some 23 };
          warnings = [];
          provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = Some "msg_e2e_stream"; model = Some "claude-sonnet-4-6"; headers = []; body = `Null };
        }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      String.iter (fun c -> push (Some (Ai_provider.Stream_part.Text { text = String.make 1 c }))) response_text;
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Stop; usage = { input_tokens = 15; output_tokens = 8; total_tokens = Some 23 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

(* Mock streaming model with tool calls *)
let make_tool_stream_model () =
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock-anthropic"
    let model_id = "claude-sonnet-4-6"

    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      incr call_count;
      let stream, push = Lwt_stream.create () in
      if !call_count = 1 then begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "Let me look that up." }));
        push
          (Some
             (Ai_provider.Stream_part.Tool_call_delta
                {
                  tool_call_type = "function";
                  tool_call_id = "toolu_1";
                  tool_name = "get_weather";
                  args_text_delta = {|{"city":"Paris"}|};
                }));
        push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = "toolu_1" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                {
                  finish_reason = Tool_calls;
                  usage = { input_tokens = 20; output_tokens = 15; total_tokens = Some 35 };
                }));
        push None
      end
      else begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "The weather in Paris is 22C and sunny." }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                { finish_reason = Stop; usage = { input_tokens = 30; output_tokens = 12; total_tokens = Some 42 } }));
        push None
      end;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

(* Mock streaming model with thinking *)
let make_thinking_stream_model () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock-anthropic"
    let model_id = "claude-sonnet-4-6"

    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      push (Some (Ai_provider.Stream_part.Reasoning { text = "Let me count the r's..." }));
      push (Some (Ai_provider.Stream_part.Text { text = "There are 3 r's in strawberry." }));
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Stop; usage = { input_tokens = 25; output_tokens = 20; total_tokens = Some 45 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

(* === generate_text E2E tests (through Anthropic provider with mock fetch) === *)

let test_generate_text_simple () =
  let config = make_mock_config mock_text_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~system:"You are helpful." ~prompt:"What is the capital of France?" ())
  in
  Alcotest.(check string) "text" "The capital of France is Paris." result.text;
  Alcotest.(check string) "finish" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  Alcotest.(check int) "1 step" 1 (List.length result.steps);
  Alcotest.(check int) "input tokens" 15 result.usage.input_tokens;
  Alcotest.(check int) "output tokens" 8 result.usage.output_tokens

let test_generate_text_with_tools () =
  let config = make_tool_loop_config () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"What's the weather in Paris?"
         ~tools:[ "get_weather", weather_tool ]
         ~max_steps:5 ())
  in
  (* 2 steps: tool call + final answer *)
  Alcotest.(check int) "2 steps" 2 (List.length result.steps);
  Alcotest.(check int) "1 tool call" 1 (List.length result.tool_calls);
  Alcotest.(check int) "1 tool result" 1 (List.length result.tool_results);
  (* Verify tool result *)
  let tr = List.nth result.tool_results 0 in
  Alcotest.(check bool) "not error" false tr.is_error;
  Alcotest.(check string) "tool name" "get_weather" tr.tool_name;
  (* Final text should include both steps *)
  Alcotest.(check bool) "has final answer" true (String.length result.text > 0);
  (* Usage aggregated across steps *)
  Alcotest.(check int) "total input" 50 result.usage.input_tokens;
  Alcotest.(check int) "total output" 27 result.usage.output_tokens

let test_generate_text_thinking () =
  let config = make_mock_config mock_thinking_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"How many r's in strawberry?" ()) in
  Alcotest.(check bool) "has reasoning" true (String.length result.reasoning > 0);
  Alcotest.(check string) "reasoning content" "Let me count the r's..." result.reasoning;
  Alcotest.(check bool) "has text" true (String.length result.text > 0);
  Alcotest.(check string) "text content" "There are 3 r's in strawberry." result.text

let test_generate_text_tool_result_content () =
  let config = make_tool_loop_config () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Weather in Paris?"
         ~tools:[ "get_weather", weather_tool ]
         ~max_steps:5 ())
  in
  (* Verify the tool result contains expected JSON *)
  let tr = List.nth result.tool_results 0 in
  let city = Yojson.Safe.Util.(member "city" tr.result |> to_string) in
  let temp = Yojson.Safe.Util.(member "temperature" tr.result |> to_int) in
  Alcotest.(check string) "tool result city" "Paris" city;
  Alcotest.(check int) "tool result temp" 22 temp

let test_generate_text_step_callback () =
  let config = make_tool_loop_config () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let step_texts = ref [] in
  let _result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Weather in Paris?"
         ~tools:[ "get_weather", weather_tool ]
         ~max_steps:5
         ~on_step_finish:(fun (step : Ai_core.Generate_text_result.step) -> step_texts := step.text :: !step_texts)
         ())
  in
  let texts = List.rev !step_texts in
  Alcotest.(check int) "2 step callbacks" 2 (List.length texts);
  Alcotest.(check string) "step 1 text" "Let me look that up." (List.nth texts 0);
  Alcotest.(check string) "step 2 text" "The weather in Paris is 22C and sunny." (List.nth texts 1)

(* === stream_text -> UIMessage stream E2E tests === *)

let test_stream_to_ui_message () =
  let model = make_stream_model "The capital of France is Paris." in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"What is the capital of France?" () in
  let ui_chunks =
    Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream ~message_id:"msg_test_1" result))
  in
  (* Verify start has message_id *)
  (match List.nth ui_chunks 0 with
  | Ai_core.Ui_message_chunk.Start { message_id = Some id; _ } -> Alcotest.(check string) "message_id" "msg_test_1" id
  | _ -> Alcotest.fail "expected Start with message_id");
  (* Verify has text deltas *)
  let text_deltas =
    List.filter_map
      (function
        | Ai_core.Ui_message_chunk.Text_delta { delta; _ } -> Some delta
        | _ -> None)
      ui_chunks
  in
  Alcotest.(check bool) "has text deltas" true (List.length text_deltas > 0);
  let full_text = String.concat "" text_deltas in
  Alcotest.(check string) "reassembled text" "The capital of France is Paris." full_text;
  (* Verify has finish *)
  let has_finish =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Finish _ -> true
        | _ -> false)
      ui_chunks
  in
  Alcotest.(check bool) "has finish" true has_finish

let test_stream_sse_format () =
  let model = make_stream_model "Hello world" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" () in
  let sse_lines =
    Lwt_main.run
      (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_sse_stream ~message_id:"msg_sse_1" result))
  in
  (* All lines start with "data: " *)
  List.iter
    (fun line ->
      Alcotest.(check bool)
        "starts with data:" true
        (String.length line >= 6 && String.equal (String.sub line 0 6) "data: "))
    sse_lines;
  (* Last should be DONE *)
  let last = List.nth sse_lines (List.length sse_lines - 1) in
  Alcotest.(check string) "ends with DONE" "data: [DONE]\n\n" last

let test_stream_pipeline_with_tools () =
  let model = make_tool_stream_model () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Weather in Paris?"
      ~tools:[ "get_weather", weather_tool ]
      ~max_steps:5 ()
  in
  let ui_chunks = Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream result)) in
  (* Verify tool interaction events present *)
  let has_tool_available =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Tool_input_available _ -> true
        | _ -> false)
      ui_chunks
  in
  let has_tool_output =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Tool_output_available _ -> true
        | _ -> false)
      ui_chunks
  in
  Alcotest.(check bool) "has tool input" true has_tool_available;
  Alcotest.(check bool) "has tool output" true has_tool_output;
  (* Verify steps *)
  let steps = Lwt_main.run result.steps in
  Alcotest.(check int) "2 steps" 2 (List.length steps);
  (* Verify usage aggregated *)
  let usage = Lwt_main.run result.usage in
  Alcotest.(check int) "total input" 50 usage.input_tokens;
  Alcotest.(check int) "total output" 27 usage.output_tokens

let test_stream_pipeline_with_thinking () =
  let model = make_thinking_stream_model () in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"How many r's in strawberry?" () in
  let ui_chunks =
    Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_stream ~send_reasoning:true result))
  in
  (* Verify reasoning deltas present *)
  let reasoning_deltas =
    List.filter_map
      (function
        | Ai_core.Ui_message_chunk.Reasoning_delta { delta; _ } -> Some delta
        | _ -> None)
      ui_chunks
  in
  Alcotest.(check bool) "has reasoning deltas" true (List.length reasoning_deltas > 0);
  (* Verify text deltas present *)
  let text_deltas =
    List.filter_map
      (function
        | Ai_core.Ui_message_chunk.Text_delta { delta; _ } -> Some delta
        | _ -> None)
      ui_chunks
  in
  Alcotest.(check bool) "has text deltas" true (List.length text_deltas > 0)

let test_stream_tool_sse_format () =
  let model = make_tool_stream_model () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Weather?" ~tools:[ "get_weather", weather_tool ] ~max_steps:5 ()
  in
  let sse_lines = Lwt_main.run (Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_sse_stream result)) in
  (* All lines are SSE formatted *)
  List.iter
    (fun line ->
      Alcotest.(check bool)
        "starts with data:" true
        (String.length line >= 6 && String.equal (String.sub line 0 6) "data: "))
    sse_lines;
  (* Should have more than just start/finish (tool events too) *)
  Alcotest.(check bool) "has many SSE events" true (List.length sse_lines > 5);
  (* Last should be DONE *)
  let last = List.nth sse_lines (List.length sse_lines - 1) in
  Alcotest.(check string) "ends with DONE" "data: [DONE]\n\n" last

let () =
  Alcotest.run "E2E Core SDK"
    [
      ( "generate_text_anthropic",
        [
          Alcotest.test_case "simple text" `Quick test_generate_text_simple;
          Alcotest.test_case "with tools" `Quick test_generate_text_with_tools;
          Alcotest.test_case "thinking" `Quick test_generate_text_thinking;
          Alcotest.test_case "tool result content" `Quick test_generate_text_tool_result_content;
          Alcotest.test_case "step callback" `Quick test_generate_text_step_callback;
        ] );
      ( "stream_to_ui_message",
        [
          Alcotest.test_case "ui message chunks" `Quick test_stream_to_ui_message;
          Alcotest.test_case "sse format" `Quick test_stream_sse_format;
          Alcotest.test_case "pipeline with tools" `Quick test_stream_pipeline_with_tools;
          Alcotest.test_case "pipeline with thinking" `Quick test_stream_pipeline_with_thinking;
          Alcotest.test_case "tool sse format" `Quick test_stream_tool_sse_format;
        ] );
    ]
