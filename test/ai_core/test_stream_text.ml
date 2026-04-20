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
      Some
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

(* Simulate the Anthropic tool-fallback path: the provider emits a synthetic [json] tool
   call whose args stream in as deltas. Stream_text must drive the partial-output parser
   off those deltas so partial JSON appears progressively — same UX as the native path. *)
let make_json_tool_fallback_stream_model ~chunks =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-json-tool-fallback"
    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      List.iter
        (fun chunk ->
          push
            (Some
               (Ai_provider.Stream_part.Tool_call_delta
                  {
                    tool_call_type = "function";
                    tool_call_id = "tc_json_1";
                    tool_name = "json";
                    args_text_delta = chunk;
                  })))
        chunks;
      push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = "tc_json_1" }));
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Tool_calls; usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let test_stream_with_json_tool_fallback () =
  (* Chunk a full JSON object across several deltas. partial_output_stream should see
     progressively more-complete objects as the deltas arrive. *)
  let chunks = [ {|{"name":|}; {|"Alice"|}; {|,"age":|}; {|30}|} ] in
  let model = make_json_tool_fallback_stream_model ~chunks in
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
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  let partials = Lwt_main.run (Lwt_stream.to_list result.partial_output_stream) in
  (check bool) "partial JSON arrived from json tool deltas" true (List.length partials > 0);
  let final_output = Lwt_main.run result.output in
  match final_output with
  | Some (`Assoc pairs) ->
    (check bool) "final has name" true (List.mem_assoc "name" pairs);
    (check bool) "final has age" true (List.mem_assoc "age" pairs)
  | Some json -> fail (Printf.sprintf "expected object, got %s" (Yojson.Basic.to_string json))
  | None -> fail "expected Some output from json tool fallback"

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
    List.mapi (fun i p -> i, p) parts
    |> List.find_map (fun (i, p) ->
      match p with
      | Ai_core.Text_stream_part.Tool_call { tool_call_id = "tc_1"; _ } -> Some i
      | _ -> None)
  in
  let tool_result_idx =
    List.mapi (fun i p -> i, p) parts
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
    {
      tool_call_id = "tc_1";
      tool_name = "dangerous_action";
      args = `Assoc [ "target", `String "prod" ];
      approved = false;
    }
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Do it"
      ~tools:[ "dangerous_action", tool ]
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

(* Mock model that always streams a tool call, for testing stop_when *)
let make_multi_step_stream_model () =
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-multi-step-stream"
    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      incr call_count;
      let stream, push = Lwt_stream.create () in
      let tc_id = Printf.sprintf "tc_%d" !call_count in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      push (Some (Ai_provider.Stream_part.Text { text = Printf.sprintf "Step %d." !call_count }));
      push
        (Some
           (Ai_provider.Stream_part.Tool_call_delta
              {
                tool_call_type = "function";
                tool_call_id = tc_id;
                tool_name = "search";
                args_text_delta = Printf.sprintf {|{"query":"step%d"}|} !call_count;
              }));
      push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = tc_id }));
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Tool_calls; usage = { input_tokens = 10; output_tokens = 10; total_tokens = Some 20 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let test_stream_stop_when_step_count () =
  let model = make_multi_step_stream_model () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Go"
      ~tools:[ "search", search_tool ]
      ~max_steps:10
      ~stop_when:[ Ai_core.Stop_condition.step_count_is 3 ]
      ()
  in
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  let steps = Lwt_main.run result.steps in
  (check int) "3 steps" 3 (List.length steps)

let test_stream_stop_when_has_tool_call () =
  (* Model that calls "search" on step 1, "done_tool" on step 2 *)
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-tool-switch-stream"
    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      incr call_count;
      let stream, push = Lwt_stream.create () in
      let tool_name =
        match !call_count with
        | 2 -> "done_tool"
        | _ -> "search"
      in
      let tc_id = Printf.sprintf "tc_%d" !call_count in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      push
        (Some
           (Ai_provider.Stream_part.Tool_call_delta
              { tool_call_type = "function"; tool_call_id = tc_id; tool_name; args_text_delta = {|{"query":"test"}|} }));
      push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = tc_id }));
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Tool_calls; usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  let model = (module M : Ai_provider.Language_model.S) in
  let done_tool =
    Ai_core.Core_tool.create ~description:"Done"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ -> Lwt.return (`String "done"))
      ()
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Go"
      ~tools:[ "search", search_tool; "done_tool", done_tool ]
      ~max_steps:10
      ~stop_when:[ Ai_core.Stop_condition.has_tool_call "done_tool" ]
      ()
  in
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  let steps = Lwt_main.run result.steps in
  (check int) "2 steps" 2 (List.length steps)

let test_stream_stop_when_on_finish_fires () =
  let model = make_multi_step_stream_model () in
  let on_finish_called = ref false in
  let finish_steps = ref 0 in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Go"
      ~tools:[ "search", search_tool ]
      ~max_steps:10
      ~stop_when:[ Ai_core.Stop_condition.step_count_is 2 ]
      ~on_finish:(fun r ->
        on_finish_called := true;
        finish_steps := List.length r.steps)
      ()
  in
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  let _steps = Lwt_main.run result.steps in
  (check bool) "on_finish called" true !on_finish_called;
  (check int) "on_finish got 2 steps" 2 !finish_steps

let test_stream_stop_when_max_steps_limits () =
  let model = make_multi_step_stream_model () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Go"
      ~tools:[ "search", search_tool ]
      ~max_steps:2
      ~stop_when:[ Ai_core.Stop_condition.step_count_is 10 ]
      ()
  in
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  let steps = Lwt_main.run result.steps in
  (* max_steps=2 is the hard limit *)
  (check int) "2 steps" 2 (List.length steps)

let run_lwt f () = Lwt_main.run (f ())

(* Mock model that fails N times on stream with retryable error, then succeeds *)
let make_stream_retry_model ~fail_count =
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-stream-retry"

    let generate _opts =
      Lwt.return
        {
          Ai_provider.Generate_result.content = [];
          finish_reason = Ai_provider.Finish_reason.Stop;
          usage = { input_tokens = 0; output_tokens = 0; total_tokens = Some 0 };
          warnings = [];
          provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = None; model = None; headers = []; body = `Null };
        }

    let stream _opts =
      incr call_count;
      if !call_count <= fail_count then
        Lwt.fail
          (Ai_provider.Provider_error.Provider_error
             { provider = "mock"; kind = Api_error { status = 529; body = "overloaded" }; is_retryable = true })
      else begin
        let stream, push = Lwt_stream.create () in
        push (Some (Ai_provider.Stream_part.Text { text = "streamed" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                {
                  finish_reason = Ai_provider.Finish_reason.Stop;
                  usage = { input_tokens = 5; output_tokens = 3; total_tokens = Some 8 };
                }));
        push None;
        Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
      end
  end in
  call_count, (module M : Ai_provider.Language_model.S)

let test_stream_retries_on_retryable_error () =
  let call_count, model = make_stream_retry_model ~fail_count:1 in
  let result = Ai_core.Stream_text.stream_text ~model ~max_retries:2 ~prompt:"test" () in
  (* Consume the text stream to completion *)
  let%lwt texts = Lwt_stream.to_list result.text_stream in
  let text = String.concat "" texts in
  (check string) "streamed text" "streamed" text;
  (check int) "called twice" 2 !call_count;
  Lwt.return_unit

let test_stream_with_smooth_transform () =
  (* "Hello world" streamed char-by-char, smoothed word-by-word *)
  let model = make_text_stream_model "Hello world" in
  let transform = Ai_core.Smooth_stream.create ~delay_ms:0 () in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Test" ~transform () in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  let texts =
    List.filter_map
      (function
        | Ai_core.Text_stream_part.Text_delta { text; _ } -> Some text
        | _ -> None)
      parts
  in
  (* Word chunking: "Hello " is emitted as a chunk, "world" flushed at end *)
  (check (list string)) "smoothed words" [ "Hello "; "world" ] texts

let test_stream_text_stream_reflects_transform () =
  let model = make_text_stream_model "Hello world" in
  let transform = Ai_core.Smooth_stream.create ~delay_ms:0 () in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Test" ~transform () in
  let text_parts = Lwt_main.run (Lwt_stream.to_list result.text_stream) in
  (* text_stream should also reflect the smoothed output *)
  (check (list string)) "text_stream smoothed" [ "Hello "; "world" ] text_parts

(* ---- Telemetry test helpers ---- *)

type Trace_core.span += Test_span of int

let make_test_collector () =
  let spans : (int * string) list ref = ref [] in
  let span_data : (int, (string * Trace_core.user_data) list ref) Hashtbl.t = Hashtbl.create 16 in
  let next_id = ref 0 in
  let callbacks : unit Trace_core.Collector.Callbacks.t =
    Trace_core.Collector.Callbacks.make
      ~enter_span:(fun () ~__FUNCTION__:_ ~__FILE__:_ ~__LINE__:_ ~level:_ ~params:_ ~data ~parent:_ name ->
        let id = !next_id in
        incr next_id;
        spans := (id, name) :: !spans;
        Hashtbl.replace span_data id (ref data);
        Test_span id)
      ~exit_span:(fun () _sp -> ())
      ~add_data_to_span:(fun () sp data ->
        match sp with
        | Test_span id ->
          (match Hashtbl.find_opt span_data id with
          | Some data_ref -> data_ref := !data_ref @ data
          | None -> ())
        | _ -> ())
      ~message:(fun () ~level:_ ~params:_ ~data:_ ~span:_ _msg -> ())
      ~metric:(fun () ~level:_ ~params:_ ~data:_ _name _metric -> ())
      ()
  in
  let collector = Trace_core.Collector.C_some ((), callbacks) in
  let get_span_names () = List.rev_map snd !spans in
  let get_span_data name =
    match List.find_opt (fun (_, n) -> String.equal n name) !spans with
    | Some (id, _) ->
      (match Hashtbl.find_opt span_data id with
      | Some data_ref -> !data_ref
      | None -> [])
    | None -> []
  in
  collector, get_span_names, get_span_data

(* ---- Telemetry tests ---- *)

let test_stream_telemetry_spans () =
  let collector, get_span_names, _get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_stream_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~function_id:"test-fn" () in
    let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hi" ~telemetry () in
    Lwt_main.run
      (let%lwt _ = Lwt_stream.to_list result.full_stream in
       let%lwt _ = result.usage in
       Lwt.return_unit);
    let names = get_span_names () in
    (check bool) "has root" true (List.mem "ai.streamText" names);
    (check bool) "has step" true (List.mem "ai.streamText.doStream" names))

let test_stream_telemetry_tool_spans () =
  let collector, get_span_names, _get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_tool_stream_model () in
    let telemetry = Ai_core.Telemetry.create ~enabled:true () in
    let result =
      Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
        ~tools:[ "search", search_tool ]
        ~max_steps:3 ~telemetry ()
    in
    Lwt_main.run
      (let%lwt _ = Lwt_stream.to_list result.full_stream in
       let%lwt _ = result.usage in
       Lwt.return_unit);
    let names = get_span_names () in
    (check bool) "has root" true (List.mem "ai.streamText" names);
    (check bool) "has tool call" true (List.mem "ai.toolCall" names);
    let step_count = List.length (List.filter (String.equal "ai.streamText.doStream") names) in
    (check int) "2 step spans" 2 step_count)

let test_stream_telemetry_disabled () =
  let collector, get_span_names, _get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_stream_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:false () in
    let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hi" ~telemetry () in
    Lwt_main.run
      (let%lwt _ = Lwt_stream.to_list result.full_stream in
       let%lwt _ = result.usage in
       Lwt.return_unit);
    let names = get_span_names () in
    (check int) "no spans when disabled" 0 (List.length names))

let test_stream_telemetry_integration_callbacks () =
  let events = ref [] in
  let integration : Ai_core.Telemetry.integration =
    {
      on_start =
        Some
          (fun e ->
            events := Printf.sprintf "start:%s" e.model.provider :: !events;
            Lwt.return_unit);
      on_step_finish =
        Some
          (fun e ->
            events := Printf.sprintf "step:%d" e.step_number :: !events;
            Lwt.return_unit);
      on_tool_call_start =
        Some
          (fun e ->
            events := Printf.sprintf "tool_start:%s" e.tool_name :: !events;
            Lwt.return_unit);
      on_tool_call_finish =
        Some
          (fun e ->
            events := Printf.sprintf "tool_finish:%s" e.tool_name :: !events;
            Lwt.return_unit);
      on_finish =
        Some
          (fun e ->
            events := Printf.sprintf "finish:%d_steps" (List.length e.steps) :: !events;
            Lwt.return_unit);
    }
  in
  let model = make_tool_stream_model () in
  let telemetry = Ai_core.Telemetry.create ~enabled:true ~integrations:[ integration ] () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search" ~tools:[ "search", search_tool ] ~max_steps:3 ~telemetry ()
  in
  Lwt_main.run
    (let%lwt _ = Lwt_stream.to_list result.full_stream in
     let%lwt _ = result.usage in
     Lwt.return_unit);
  let evts = List.rev !events in
  (check bool) "has start" true (List.exists (fun s -> String.starts_with ~prefix:"start:" s) evts);
  (check bool) "has tool_start" true (List.exists (fun s -> String.starts_with ~prefix:"tool_start:" s) evts);
  (check bool) "has tool_finish" true (List.exists (fun s -> String.starts_with ~prefix:"tool_finish:" s) evts);
  (check bool) "has step" true (List.exists (fun s -> String.starts_with ~prefix:"step:" s) evts);
  (check bool) "has finish" true (List.exists (fun s -> String.starts_with ~prefix:"finish:" s) evts)

let test_stream_telemetry_root_attributes () =
  let collector, _get_span_names, get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_stream_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~function_id:"my-fn" () in
    let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hi" ~telemetry () in
    Lwt_main.run
      (let%lwt _ = Lwt_stream.to_list result.full_stream in
       let%lwt _ = result.usage in
       Lwt.return_unit);
    let data = get_span_data "ai.streamText" in
    (check string) "operation.name" "ai.streamText my-fn"
      (match List.assoc_opt "operation.name" data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "ai.model.provider" "mock"
      (match List.assoc_opt "ai.model.provider" data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "ai.model.id" "mock-stream"
      (match List.assoc_opt "ai.model.id" data with
      | Some (`String s) -> s
      | _ -> ""))

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
      ( "stop_when",
        [
          test_case "step_count" `Quick test_stream_stop_when_step_count;
          test_case "has_tool_call" `Quick test_stream_stop_when_has_tool_call;
          test_case "on_finish_fires" `Quick test_stream_stop_when_on_finish_fires;
          test_case "max_steps_limits" `Quick test_stream_stop_when_max_steps_limits;
        ] );
      ( "transform",
        [
          test_case "smooth_stream" `Quick test_stream_with_smooth_transform;
          test_case "text_stream_reflects" `Quick test_stream_text_stream_reflects_transform;
        ] );
      ( "output",
        [
          test_case "with_object_output" `Quick test_stream_with_object_output;
          test_case "with_json_tool_fallback" `Quick test_stream_with_json_tool_fallback;
          test_case "without_output" `Quick test_stream_without_output;
        ] );
      "retry", [ test_case "retries_on_retryable_error" `Quick (run_lwt test_stream_retries_on_retryable_error) ];
      ( "telemetry",
        [
          test_case "spans" `Quick test_stream_telemetry_spans;
          test_case "tool_spans" `Quick test_stream_telemetry_tool_spans;
          test_case "disabled_no_spans" `Quick test_stream_telemetry_disabled;
          test_case "integration_callbacks" `Quick test_stream_telemetry_integration_callbacks;
          test_case "root_attributes" `Quick test_stream_telemetry_root_attributes;
        ] );
    ]
