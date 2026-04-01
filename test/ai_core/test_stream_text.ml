open Melange_json.Primitives
open Alcotest

type query_args = { query : string } [@@json.allow_extra_fields] [@@deriving of_json]

(* Mock streaming model -- emits text deltas *)
let make_text_stream_model response_text =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-stream"

    let generate _opts =
      Lwt.return
        {
          Ai_provider.Generate_result.content = [ Ai_provider.Content.Text { text = response_text } ];
          finish_reason = Stop;
          usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
          warnings = [];
          provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = None; model = None; headers = []; body = `Null };
        }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      (* Split text into characters for realistic streaming *)
      String.iter (fun c -> push (Some (Ai_provider.Stream_part.Text { text = String.make 1 c }))) response_text;
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Stop; usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

(* Mock model that streams a tool call then text on second call *)
let make_tool_stream_model () =
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-tool-stream"

    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      incr call_count;
      let stream, push = Lwt_stream.create () in
      if !call_count = 1 then begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "Searching..." }));
        push
          (Some
             (Ai_provider.Stream_part.Tool_call_delta
                {
                  tool_call_type = "function";
                  tool_call_id = "tc_1";
                  tool_name = "search";
                  args_text_delta = {|{"query":"test"}|};
                }));
        push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = "tc_1" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                { finish_reason = Tool_calls; usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 } }));
        push None
      end
      else begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "Found it!" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                { finish_reason = Stop; usage = { input_tokens = 20; output_tokens = 5; total_tokens = Some 25 } }));
        push None
      end;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let search_tool : Ai_core.Core_tool.t =
  {
    description = Some "Search";
    parameters = `Assoc [ "type", `String "object" ];
    execute =
      (fun args ->
        let q = try (query_args_of_json args).query with _ -> "?" in
        Lwt.return (`String (Printf.sprintf "Results for: %s" q)));
    needs_approval = None;
  }

(* Tests *)

let test_simple_stream () =
  let model = make_text_stream_model "Hello" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Say hello" () in
  (* Collect text *)
  let texts = Lwt_main.run (Lwt_stream.to_list result.text_stream) in
  let full_text = String.concat "" texts in
  (check string) "text" "Hello" full_text;
  (* Check usage resolves *)
  let usage = Lwt_main.run result.usage in
  (check int) "input" 10 usage.input_tokens

let test_full_stream_events () =
  let model = make_text_stream_model "Hi" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" () in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Should have: Start, Start_step, Text_start, Text_delta(s), Text_end, Finish_step, Finish *)
  let has_start =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Start -> true
        | _ -> false)
      parts
  in
  let has_finish =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Finish _ -> true
        | _ -> false)
      parts
  in
  (check bool) "has Start" true has_start;
  (check bool) "has Finish" true has_finish

let test_tool_stream_loop () =
  let model = make_tool_stream_model () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search" ~tools:[ "search", search_tool ] ~max_steps:3 ()
  in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Should include tool call, tool result, and final text *)
  let has_tool_call =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_call _ -> true
        | _ -> false)
      parts
  in
  let has_tool_result =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_result _ -> true
        | _ -> false)
      parts
  in
  (check bool) "has Tool_call" true has_tool_call;
  (check bool) "has Tool_result" true has_tool_result;
  (* Check steps *)
  let steps = Lwt_main.run result.steps in
  (check int) "2 steps" 2 (List.length steps);
  (* Check aggregated usage *)
  let usage = Lwt_main.run result.usage in
  (check int) "total input" 30 usage.input_tokens

let test_on_chunk_callback () =
  let chunk_count = ref 0 in
  let model = make_text_stream_model "Hi" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~on_chunk:(fun _ -> incr chunk_count) () in
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (check bool) "chunks received" true (!chunk_count > 0)

let test_finish_reason () =
  let model = make_text_stream_model "Done" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Test" () in
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  let fr = Lwt_main.run result.finish_reason in
  (check string) "stop" "stop" (Ai_provider.Finish_reason.to_string fr)

let test_stream_with_object_output () =
  let json_text = {|{"name":"Alice","age":30}|} in
  let model = make_text_stream_model json_text in
  let schema =
    `Assoc
      [
        "type", `String "object";
        ( "properties",
          `Assoc [ "name", `Assoc [ "type", `String "string" ]; "age", `Assoc [ "type", `String "integer" ] ] );
        "required", `List [ `String "name"; `String "age" ];
        "additionalProperties", `Bool false;
      ]
  in
  let output = Ai_core.Output.object_ ~name:"person" ~schema () in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Give me a person" ~output () in
  (* Drain full_stream to let background task complete *)
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Check partial output stream has entries *)
  let partials = Lwt_main.run (Lwt_stream.to_list result.partial_output_stream) in
  (check bool) "has partial outputs" true (List.length partials > 0);
  (* Check final output resolves to parsed JSON *)
  let final_output = Lwt_main.run result.output in
  match final_output with
  | Some json -> (check string) "output json" json_text (Yojson.Basic.to_string json)
  | None -> fail "expected Some output"

let test_stream_without_output () =
  let model = make_text_stream_model "Hello world" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Say hello" () in
  (* Drain full_stream to let background task complete *)
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Check partial output stream is empty *)
  let partials = Lwt_main.run (Lwt_stream.to_list result.partial_output_stream) in
  (check int) "no partial outputs" 0 (List.length partials);
  (* Check output is None *)
  let final_output = Lwt_main.run result.output in
  (check bool) "output is None" true (Option.is_none final_output)

let make_approval_stream_model () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-approval-stream"
    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      push (Some (Ai_provider.Stream_part.Text { text = "Let me check." }));
      push
        (Some
           (Ai_provider.Stream_part.Tool_call_delta
              {
                tool_call_type = "function";
                tool_call_id = "tc_1";
                tool_name = "dangerous_action";
                args_text_delta = {|{"target":"prod"}|};
              }));
      push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = "tc_1" }));
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Tool_calls; usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let approval_tool : Ai_core.Core_tool.t =
  Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
    ~parameters:(`Assoc [ "type", `String "object" ])
    ~execute:(fun _ -> Lwt.return (`String "executed"))
    ()

let test_approval_stops_stream_loop () =
  let model = make_approval_stream_model () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Do it" ~tools:[ "dangerous_action", approval_tool ] ~max_steps:3 ()
  in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Should have Tool_approval_request, NO Tool_result *)
  let has_approval =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_approval_request _ -> true
        | _ -> false)
      parts
  in
  let has_tool_result =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_result _ -> true
        | _ -> false)
      parts
  in
  (check bool) "has approval request" true has_approval;
  (check bool) "no tool result" false has_tool_result;
  let steps = Lwt_main.run result.steps in
  (check int) "1 step" 1 (List.length steps);
  match steps with
  | step :: _ ->
    (check int) "1 tool call" 1 (List.length step.tool_calls);
    (check int) "0 tool results" 0 (List.length step.tool_results)
  | [] -> Alcotest.fail "expected at least one step"

let make_approved_stream_model () =
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-approved-stream"
    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      incr call_count;
      let stream, push = Lwt_stream.create () in
      if !call_count = 1 then begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "Let me check." }));
        push
          (Some
             (Ai_provider.Stream_part.Tool_call_delta
                {
                  tool_call_type = "function";
                  tool_call_id = "tc_1";
                  tool_name = "dangerous_action";
                  args_text_delta = {|{"target":"prod"}|};
                }));
        push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = "tc_1" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                { finish_reason = Tool_calls; usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 } }));
        push None
      end
      else begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "Done!" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                { finish_reason = Stop; usage = { input_tokens = 20; output_tokens = 5; total_tokens = Some 25 } }));
        push None
      end;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let test_approved_tool_executes_stream () =
  (* Model that just returns text — the tool was already executed in the initial step *)
  let model = make_text_stream_model "Done!" in
  let tool =
    Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ -> Lwt.return (`String "executed"))
      ()
  in
  let pending : Ai_core.Generate_text_result.pending_tool_approval =
    {
      tool_call_id = "tc_1";
      tool_name = "dangerous_action";
      args = `Assoc [ "target", `String "prod" ];
      approved = true;
    }
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Do it"
      ~tools:[ "dangerous_action", tool ]
      ~pending_tool_approvals:[ pending ] ~max_steps:3 ()
  in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Initial step should emit Tool_call before Tool_result *)
  let has_tool_call =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_call { tool_call_id = "tc_1"; _ } -> true
        | _ -> false)
      parts
  in
  let has_tool_result =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_result { tool_call_id = "tc_1"; _ } -> true
        | _ -> false)
      parts
  in
  (check bool) "has tool call" true has_tool_call;
  (check bool) "has tool result" true has_tool_result;
  (* Verify Tool_call appears before Tool_result *)
  let tool_call_idx =
    List.mapi (fun i p -> (i, p)) parts
    |> List.find_map (fun (i, p) ->
      match p with
      | Ai_core.Text_stream_part.Tool_call { tool_call_id = "tc_1"; _ } -> Some i
      | _ -> None)
  in
  let tool_result_idx =
    List.mapi (fun i p -> (i, p)) parts
    |> List.find_map (fun (i, p) ->
      match p with
      | Ai_core.Text_stream_part.Tool_result { tool_call_id = "tc_1"; _ } -> Some i
      | _ -> None)
  in
  (match tool_call_idx, tool_result_idx with
  | Some ci, Some ri -> (check bool) "tool_call before tool_result" true (ci < ri)
  | _ -> Alcotest.fail "expected both tool_call and tool_result");
  let steps = Lwt_main.run result.steps in
  (* Initial step (tool execution) + LLM step *)
  (check int) "2 steps" 2 (List.length steps)

let test_denied_tool_emits_output_denied () =
  let model = make_text_stream_model "Done!" in
  let tool =
    Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ -> Lwt.return (`String "should not execute"))
      ()
  in
  let pending : Ai_core.Generate_text_result.pending_tool_approval =
    { tool_call_id = "tc_1"; tool_name = "dangerous_action"; args = `Assoc [ "target", `String "prod" ]; approved = false }
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Do it" ~tools:[ "dangerous_action", tool ]
      ~pending_tool_approvals:[ pending ] ~max_steps:3 ()
  in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Should emit Tool_output_denied, NOT Tool_result *)
  let has_denied =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_output_denied { tool_call_id = "tc_1" } -> true
        | _ -> false)
      parts
  in
  let has_error_result =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_result { tool_call_id = "tc_1"; is_error = true; _ } -> true
        | _ -> false)
      parts
  in
  (check bool) "has Tool_output_denied" true has_denied;
  (check bool) "no error Tool_result" false has_error_result

let make_mixed_stream_model () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-mixed-stream"
    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      push (Some (Ai_provider.Stream_part.Text { text = "Doing both." }));
      push
        (Some
           (Ai_provider.Stream_part.Tool_call_delta
              {
                tool_call_type = "function";
                tool_call_id = "tc_safe";
                tool_name = "safe_action";
                args_text_delta = {|{"query":"test"}|};
              }));
      push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = "tc_safe" }));
      push
        (Some
           (Ai_provider.Stream_part.Tool_call_delta
              {
                tool_call_type = "function";
                tool_call_id = "tc_danger";
                tool_name = "dangerous_action";
                args_text_delta = {|{"target":"prod"}|};
              }));
      push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = "tc_danger" }));
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Tool_calls; usage = { input_tokens = 10; output_tokens = 15; total_tokens = Some 25 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let test_mixed_tools_safe_executes_stream () =
  let model = make_mixed_stream_model () in
  let safe_tool =
    Ai_core.Core_tool.create ~description:"Safe"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ -> Lwt.return (`String "safe result"))
      ()
  in
  let dangerous_tool =
    Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ -> Lwt.return (`String "dangerous result"))
      ()
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Do both"
      ~tools:[ "safe_action", safe_tool; "dangerous_action", dangerous_tool ]
      ~max_steps:3 ()
  in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Only dangerous_action should get approval request *)
  let approval_requests =
    List.filter_map
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_approval_request { tool_call_id; _ } -> Some tool_call_id
        | _ -> None)
      parts
  in
  (* Safe tool should have a Tool_result *)
  let safe_tool_results =
    List.filter_map
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_result { tool_call_id; _ } -> Some tool_call_id
        | _ -> None)
      parts
  in
  (match approval_requests with
  | [ id ] -> (check string) "approval for dangerous" "tc_danger" id
  | _ -> Alcotest.fail "expected exactly 1 approval request");
  (match safe_tool_results with
  | [ id ] -> (check string) "safe tool executed" "tc_safe" id
  | _ -> Alcotest.fail "expected exactly 1 safe tool result");
  let steps = Lwt_main.run result.steps in
  match steps with
  | [ step ] ->
    (check int) "step has 2 tool calls" 2 (List.length step.tool_calls);
    (check int) "step has 1 tool result" 1 (List.length step.tool_results)
  | _ -> Alcotest.fail "expected exactly 1 step"

let () =
  run "Stream_text"
    [
      ( "basic",
        [
          test_case "simple" `Quick test_simple_stream;
          test_case "full_events" `Quick test_full_stream_events;
          test_case "finish_reason" `Quick test_finish_reason;
        ] );
      ( "tools",
        [
          test_case "tool_loop" `Quick test_tool_stream_loop;
          test_case "approval_stops_stream_loop" `Quick test_approval_stops_stream_loop;
          test_case "approved_tool_executes" `Quick test_approved_tool_executes_stream;
          test_case "denied_emits_output_denied" `Quick test_denied_tool_emits_output_denied;
          test_case "mixed_tools_safe_executes" `Quick test_mixed_tools_safe_executes_stream;
        ] );
      "callbacks", [ test_case "on_chunk" `Quick test_on_chunk_callback ];
      ( "output",
        [
          test_case "with_object_output" `Quick test_stream_with_object_output;
          test_case "without_output" `Quick test_stream_without_output;
        ] );
    ]
