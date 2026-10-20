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
              {
                finish_reason = Stop;
                usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
                provider_metadata = None;
              }));
      push None;
      Lwt.return
        {
          Ai_provider.Stream_result.stream;
          warnings = [];
          raw_response = Some { id = Some "stream-1"; model = Some "actual-stream-model"; headers = []; body = `Null };
        }
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
                {
                  finish_reason = Tool_calls;
                  usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 };
                  provider_metadata = None;
                }));
        push None
      end
      else begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "Found it!" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                {
                  finish_reason = Stop;
                  usage = { input_tokens = 20; output_tokens = 5; total_tokens = Some 25 };
                  provider_metadata = None;
                }));
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
    provider_options = Ai_provider.Provider_options.empty;
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
  (check int) "input" 10 usage.input_tokens;
  match Lwt_main.run result.steps with
  | [ step ] -> (check (option string)) "actual response model" (Some "actual-stream-model") step.response_model
  | _ -> fail "expected one step"

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
              {
                finish_reason = Tool_calls;
                usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 };
                provider_metadata = None;
              }));
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
              {
                finish_reason = Tool_calls;
                usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 };
                provider_metadata = None;
              }));
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
                {
                  finish_reason = Tool_calls;
                  usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 };
                  provider_metadata = None;
                }));
        push None
      end
      else begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "Done!" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                {
                  finish_reason = Stop;
                  usage = { input_tokens = 20; output_tokens = 5; total_tokens = Some 25 };
                  provider_metadata = None;
                }));
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
              {
                finish_reason = Tool_calls;
                usage = { input_tokens = 10; output_tokens = 15; total_tokens = Some 25 };
                provider_metadata = None;
              }));
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
              {
                finish_reason = Tool_calls;
                usage = { input_tokens = 10; output_tokens = 10; total_tokens = Some 20 };
                provider_metadata = None;
              }));
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
              {
                finish_reason = Tool_calls;
                usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
                provider_metadata = None;
              }));
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
             {
               provider = "mock";
               kind = Api_error { status = 529; body = "overloaded" };
               is_retryable = true;
               retry_after_s = None;
             })
      else begin
        let stream, push = Lwt_stream.create () in
        push (Some (Ai_provider.Stream_part.Text { text = "streamed" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                {
                  finish_reason = Ai_provider.Finish_reason.Stop;
                  usage = { input_tokens = 5; output_tokens = 3; total_tokens = Some 8 };
                  provider_metadata = None;
                }));
        push None;
        Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
      end
  end in
  call_count, (module M : Ai_provider.Language_model.S)

let test_stream_retries_on_retryable_error () =
  let call_count, model = make_stream_retry_model ~fail_count:1 in
  let result = Ai_core.Stream_text.stream_text ~model ~max_retries:2 ~max_retry_delay_ms:0 ~prompt:"test" () in
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

(* Verify Stream_text_result.provider_metadata resolves to Some _ when the
   provider attaches metadata to the Finish chunk. Mirrors the cache-metrics
   path on the non-streaming generate_text result. *)
let make_provider_metadata_stream_model () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-pm"
    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      push (Some (Ai_provider.Stream_part.Text { text = "hi" }));
      push
        (Some
           (Ai_provider.Stream_part.Finish
              {
                finish_reason = Stop;
                usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
                provider_metadata =
                  Some
                    (Ai_provider.Provider_options.of_provider_metadata
                       (`Assoc
                          [
                            ( "anthropic",
                              `Assoc [ "cache_creation_input_tokens", `Int 20; "cache_read_input_tokens", `Int 80 ] );
                          ]));
              }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let test_stream_surfaces_provider_metadata () =
  let model = make_provider_metadata_stream_model () in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"hi" () in
  let _full = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  let pm = Lwt_main.run result.provider_metadata in
  match pm with
  | Some _ -> ()
  | None -> fail "expected provider_metadata to be Some after a Finish chunk carrying metadata"

(* Abort *)

(* The first call streams a call to the [search] tool. Later calls stream
   "Found" and then hang like a slow provider until the abort signal fires,
   which ends the stream without a Finish part, as Stream_pump.pump does.
   [calls] counts model calls and [signals] records, per call, whether the
   call options carried the abort signal. *)
let make_abort_stream_model () =
  let calls = ref 0 in
  let signals = ref [] in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-abort-stream"

    let generate _opts = Lwt.fail_with "not implemented"

    let stream (opts : Ai_provider.Call_options.t) =
      incr calls;
      signals := Option.is_some opts.abort_signal :: !signals;
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      (match !calls with
      | 1 ->
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
                {
                  finish_reason = Tool_calls;
                  usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 };
                  provider_metadata = None;
                }));
        push None
      | _ ->
        push (Some (Ai_provider.Stream_part.Text { text = "Found" }));
        Option.iter
          (fun signal -> ignore (Ai_provider.Abort_signal.on_abort signal (fun () -> push None) : unit -> unit))
          opts.abort_signal);
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  calls, signals, (module M : Ai_provider.Language_model.S)

let part_name (part : Ai_core.Text_stream_part.t) =
  match part with
  | Start -> "start"
  | Start_step -> "start-step"
  | Text_start _ -> "text-start"
  | Text_delta _ -> "text-delta"
  | Text_end _ -> "text-end"
  | Reasoning_start _ -> "reasoning-start"
  | Reasoning_delta _ -> "reasoning-delta"
  | Reasoning_end _ -> "reasoning-end"
  | Tool_call _ -> "tool-call"
  | Tool_call_delta _ -> "tool-call-delta"
  | Tool_result _ -> "tool-result"
  | Tool_output_denied _ -> "tool-output-denied"
  | Tool_approval_request _ -> "tool-approval-request"
  | Source _ -> "source"
  | File _ -> "file"
  | Finish_step _ -> "finish-step"
  | Finish _ -> "finish"
  | Error _ -> "error"
  | Abort { reason = None } -> "abort"
  | Abort { reason = Some reason } -> "abort:" ^ reason

let failed_with_aborted promise =
  match Lwt.state promise with
  | Lwt.Fail Ai_provider.Abort_signal.Aborted -> true
  | Lwt.Fail _ | Lwt.Return _ | Lwt.Sleep -> false

let check_result_aborted (result : Ai_core.Stream_text_result.t) =
  (check bool) "usage failed with Aborted" true (failed_with_aborted result.usage);
  (check bool) "finish_reason failed with Aborted" true (failed_with_aborted result.finish_reason);
  (check bool) "steps failed with Aborted" true (failed_with_aborted result.steps)

(* Reads [stream] up to and including the first part that satisfies [f]. *)
let rec read_until f stream ~acc =
  match%lwt Lwt_stream.get stream with
  | None -> Lwt.return (List.rev acc)
  | Some part when f part -> Lwt.return (List.rev (part :: acc))
  | Some part -> read_until f stream ~acc:(part :: acc)

let test_abort_mid_stream () =
  let calls, signals, model = make_abort_stream_model () in
  let signal, abort = Lwt.wait () in
  let aborted_with = ref None in
  let step_finishes = ref 0 in
  let finished = ref false in
  let chunks = ref [] in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", search_tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_abort:(fun ~steps -> aborted_with := Some steps)
      ~on_step_finish:(fun _ -> incr step_finishes)
      ~on_finish:(fun _ -> finished := true)
      ~on_chunk:(fun part -> chunks := part_name part :: !chunks)
      ()
  in
  let%lwt before =
    read_until
      (function
        | Ai_core.Text_stream_part.Text_delta _ -> true
        | _ -> false)
      result.full_stream ~acc:[]
  in
  Lwt.wakeup_later abort ();
  let%lwt after = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  (check (list string))
    "parts"
    [
      "start";
      "start-step";
      "tool-call-delta";
      "tool-call";
      "tool-result";
      "finish-step";
      "start-step";
      "text-start";
      "text-delta";
      "abort";
    ]
    (List.map part_name (before @ after));
  (* As upstream's onChunk, [on_chunk] sees every part but the [Abort]. *)
  (check (list string))
    "on_chunk sees every part but abort"
    (List.filter (fun name -> not (String.equal name "abort")) (List.map part_name (before @ after)))
    (List.rev !chunks);
  (check (option (list string)))
    "on_abort gets the first step" (Some [ "search" ])
    (Option.map
       (List.concat_map (fun (step : Ai_core.Generate_text_result.step) ->
          List.map (fun (tc : Ai_core.Generate_text_result.tool_call) -> tc.tool_name) step.tool_calls))
       !aborted_with);
  (check int) "on_step_finish for the first step only" 1 !step_finishes;
  (check bool) "on_finish not called" false !finished;
  check_result_aborted result;
  (check int) "model calls" 2 !calls;
  (check (list bool)) "every call got the signal" [ true; true ] !signals;
  Lwt.return_unit

(* As upstream, [Start] comes before the [Abort] part even when the signal
   fired before the call. *)
let test_abort_before_start () =
  let calls, (_ : bool list ref), model = make_abort_stream_model () in
  let aborted_with = ref None in
  let chunks = ref [] in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search" ~abort_signal:Lwt.return_unit
      ~on_abort:(fun ~steps -> aborted_with := Some (List.length steps))
      ~on_chunk:(fun part -> chunks := part_name part :: !chunks)
      ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt texts = Lwt_stream.to_list result.text_stream in
  let%lwt () = Lwt.pause () in
  (check (list string)) "parts" [ "start"; "abort" ] (List.map part_name parts);
  (check (list string)) "on_chunk parts" [ "start" ] (List.rev !chunks);
  (check (list string)) "no text" [] texts;
  (check (option int)) "on_abort with no steps" (Some 0) !aborted_with;
  check_result_aborted result;
  (check int) "model never called" 0 !calls;
  Lwt.return_unit

(* Runs a search that fires the abort signal from [on_step_finish] or from the
   tool. Returns the parts, the number of steps on_abort got, the model call
   count and the tool run count. *)
let run_abort_in_first_step ~in_tool =
  let calls, (_ : bool list ref), model = make_abort_stream_model () in
  let signal, abort = Lwt.wait () in
  let tool_runs = ref 0 in
  let aborted_steps = ref None in
  let tool =
    {
      search_tool with
      execute =
        Some
          (fun (_ : Yojson.Basic.t) ->
            incr tool_runs;
            if in_tool then Lwt.wakeup_later abort ();
            Lwt.return (`String "results"));
    }
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_step_finish:(fun (_ : Ai_core.Generate_text_result.step) -> if not in_tool then Lwt.wakeup_later abort ())
      ~on_abort:(fun ~steps -> aborted_steps := Some (List.length steps))
      ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  check_result_aborted result;
  Lwt.return (List.map part_name parts, !aborted_steps, !calls, !tool_runs)

let test_abort_in_on_step_finish () =
  let%lwt parts, aborted_steps, calls, tool_runs = run_abort_in_first_step ~in_tool:false in
  (check (list string))
    "parts"
    [ "start"; "start-step"; "tool-call-delta"; "tool-call"; "tool-result"; "finish-step"; "abort" ]
    parts;
  (check (option int)) "on_abort gets the finished step" (Some 1) aborted_steps;
  (check int) "one model call" 1 calls;
  (check int) "one tool run" 1 tool_runs;
  Lwt.return_unit

(* The tool runs before its step finishes, so on_abort gets no steps, and its
   result comes after the abort, so the stream drops it. *)
let test_abort_during_tool () =
  let%lwt parts, aborted_steps, calls, tool_runs = run_abort_in_first_step ~in_tool:true in
  (check (list string)) "parts" [ "start"; "start-step"; "tool-call-delta"; "tool-call"; "abort" ] parts;
  (check (option int)) "on_abort gets no steps" (Some 0) aborted_steps;
  (check int) "one model call" 1 calls;
  (check int) "one tool run" 1 tool_runs;
  Lwt.return_unit

(* The UI stream ends with the abort chunk and has no finish chunk. *)
let test_abort_ui_stream () =
  let (_ : int ref), (_ : bool list ref), model = make_abort_stream_model () in
  let signal, abort = Lwt.wait () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", search_tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_chunk:(function
        | Text_delta _ -> Lwt.wakeup_later abort ()
        | _ -> ())
      ()
  in
  let%lwt sse = Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_sse_stream result) in
  let types =
    List.filter_map
      (fun event ->
        match String.trim event with
        | "data: [DONE]" -> Some "[DONE]"
        | line ->
          let json = Yojson.Basic.from_string (String.sub line 6 (String.length line - 6)) in
          Some (Yojson.Basic.Util.to_string (Yojson.Basic.Util.member "type" json)))
      sse
  in
  (check (list string))
    "chunk types"
    [
      "start";
      "start-step";
      "tool-input-start";
      "tool-input-delta";
      "tool-input-available";
      "tool-output-available";
      "finish-step";
      "start-step";
      "text-start";
      "text-delta";
      "abort";
      "[DONE]";
    ]
    types;
  (check string) "abort chunk" "data: {\"type\":\"abort\"}" (String.trim (List.nth sse (List.length sse - 2)));
  Lwt.return_unit

(* Collects [stream], or gives [None] when it has not closed within a second,
   so a stream that never closes fails the test instead of hanging it. *)
let to_list_or_hang stream =
  Lwt.pick
    [
      (let%lwt parts = Lwt_stream.to_list stream in
       Lwt.return_some parts);
      (let%lwt () = Lwt_unix.sleep 1.0 in
       Lwt.return_none);
    ]

let failed_with_failure message promise =
  match Lwt.state promise with
  | Lwt.Fail (Failure m) -> String.equal m message
  | Lwt.Fail _ | Lwt.Return _ | Lwt.Sleep -> false

(* An exception from [on_chunk] on the [Finish] part becomes an [Error] part,
   and every stream and promise still settles. *)
let test_on_chunk_raises_on_finish () =
  let model = make_text_stream_model "Hi" in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello"
      ~on_chunk:(function
        | Finish _ -> failwith "on_chunk failed"
        | _ -> ())
      ()
  in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt texts = to_list_or_hang result.text_stream in
  let%lwt partial = to_list_or_hang result.partial_output_stream in
  let%lwt () = Lwt.pause () in
  (check (option (list string)))
    "parts"
    (Some
       [ "start"; "start-step"; "text-start"; "text-delta"; "text-delta"; "text-end"; "finish-step"; "finish"; "error" ])
    (Option.map (List.map part_name) parts);
  (check (option (list string))) "text_stream closes" (Some [ "H"; "i" ]) texts;
  (check bool) "partial_output_stream closes" true (Option.is_some partial);
  (check bool) "usage fails" true (failed_with_failure "on_chunk failed" result.usage);
  (check bool) "finish_reason fails" true (failed_with_failure "on_chunk failed" result.finish_reason);
  (check bool) "steps fails" true (failed_with_failure "on_chunk failed" result.steps);
  (check bool) "output resolves to None" true
    (match Lwt.state result.output with
    | Lwt.Return None -> true
    | Lwt.Return (Some _) | Lwt.Fail _ | Lwt.Sleep -> false);
  Lwt.return_unit

(* [on_finish] runs after the call has settled, so its exception changes
   nothing. *)
let test_on_finish_raises () =
  let model = make_text_stream_model "Hi" in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~on_finish:(fun _ -> failwith "on_finish failed") ()
  in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt partial = to_list_or_hang result.partial_output_stream in
  let%lwt usage = result.usage in
  let%lwt steps = result.steps in
  (check (option string))
    "last part" (Some "finish")
    (Option.bind parts (fun parts -> Option.map part_name (List.nth_opt parts (List.length parts - 1))));
  (check bool) "partial_output_stream closes" true (Option.is_some partial);
  (check int) "usage" 10 usage.input_tokens;
  (check int) "one step" 1 (List.length steps);
  Lwt.return_unit

(* As upstream, [Finish_step] is emitted before [on_step_finish] runs. *)
let test_finish_step_before_on_step_finish () =
  let model = make_text_stream_model "Hi" in
  let log = ref [] in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello"
      ~on_chunk:(function
        | Finish_step _ -> log := "finish-step" :: !log
        | Finish _ -> log := "finish" :: !log
        | _ -> ())
      ~on_step_finish:(fun (_ : Ai_core.Generate_text_result.step) -> log := "on_step_finish" :: !log)
      ()
  in
  let%lwt (_ : Ai_core.Text_stream_part.t list) = Lwt_stream.to_list result.full_stream in
  (check (list string)) "order" [ "finish-step"; "on_step_finish"; "finish" ] (List.rev !log);
  Lwt.return_unit

(* The abort path ignores exceptions from [on_chunk] and still closes. *)
let test_abort_on_chunk_raises () =
  let (_ : int ref), (_ : bool list ref), model = make_abort_stream_model () in
  let aborted = ref false in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search" ~abort_signal:Lwt.return_unit
      ~on_abort:(fun ~steps:_ -> aborted := true)
      ~on_chunk:(fun (_ : Ai_core.Text_stream_part.t) -> failwith "on_chunk failed")
      ()
  in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  (check (option (list string))) "parts" (Some [ "start"; "abort" ]) (Option.map (List.map part_name) parts);
  (check bool) "on_abort called" true !aborted;
  check_result_aborted result;
  Lwt.return_unit

(* An abort stops reading the provider stream. *)
let test_abort_stops_reading_provider () =
  let provider_stream =
    Lwt_stream.of_list
      (Ai_provider.Stream_part.Stream_start { warnings = [] }
       :: List.map (fun text -> Ai_provider.Stream_part.Text { text }) [ {|{"a":|}; "1"; {|,"b":2|}; "}" ]
      @ [
          Ai_provider.Stream_part.Finish
            {
              finish_reason = Stop;
              usage = { input_tokens = 1; output_tokens = 1; total_tokens = Some 2 };
              provider_metadata = None;
            };
        ])
  in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-buffered"
    let generate _opts = Lwt.fail_with "not implemented"
    let stream _opts =
      Lwt.return { Ai_provider.Stream_result.stream = provider_stream; warnings = []; raw_response = None }
  end in
  let signal, abort = Lwt.wait () in
  let result =
    Ai_core.Stream_text.stream_text
      ~model:(module M)
      ~prompt:"x" ~abort_signal:signal
      ~on_chunk:(function
        | Text_delta _ -> Lwt.wakeup_later abort ()
        | _ -> ())
      ()
  in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt partial = to_list_or_hang result.partial_output_stream in
  let%lwt () = Lwt.pause () in
  (check (option (list string)))
    "parts"
    (Some [ "start"; "start-step"; "text-start"; "text-delta"; "abort" ])
    (Option.map (List.map part_name) parts);
  (check bool) "partial_output_stream closes" true (Option.is_some partial);
  (check bool) "provider parts left unread" true (Lwt_stream.get_available provider_stream <> []);
  check_result_aborted result;
  Lwt.return_unit

(* The step that runs pending approvals counts as finished for [on_abort], as it
   does for [steps]. *)
let test_abort_after_pending_approvals () =
  let (_ : int ref), (_ : bool list ref), model = make_abort_stream_model () in
  let signal, abort = Lwt.wait () in
  let aborted_with = ref None in
  let pending : Ai_core.Generate_text_result.pending_tool_approval =
    { tool_call_id = "tc_0"; tool_name = "search"; args = `Assoc [ "query", `String "first" ]; approved = true }
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", search_tool ]
      ~pending_tool_approvals:[ pending ] ~max_steps:4 ~abort_signal:signal
      ~on_abort:(fun ~steps -> aborted_with := Some steps)
      ~on_chunk:(function
        | Text_delta _ -> Lwt.wakeup_later abort ()
        | _ -> ())
      ()
  in
  let%lwt (_ : Ai_core.Text_stream_part.t list option) = to_list_or_hang result.full_stream in
  (check (option (list (list string))))
    "on_abort gets the approval step and the search step"
    (Some [ [ "tc_0" ]; [ "tc_1" ] ])
    (Option.map
       (List.map (fun (step : Ai_core.Generate_text_result.step) ->
          List.map (fun (tc : Ai_core.Generate_text_result.tool_call) -> tc.tool_call_id) step.tool_calls))
       !aborted_with);
  Lwt.return_unit

(* [on_chunk] gets the [Error] part too, as upstream's onChunk does. An
   exception it raises there is ignored, so the call still ends with the
   provider's error. *)
let test_on_chunk_gets_error () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-failing"
    let generate _opts = Lwt.fail_with "not implemented"
    let stream _opts = Lwt.fail_with "provider down"
  end in
  let chunks = ref [] in
  let result =
    Ai_core.Stream_text.stream_text
      ~model:(module M)
      ~prompt:"Hello" ~max_retries:0
      ~on_chunk:(fun part ->
        chunks := part_name part :: !chunks;
        match part with
        | Error _ -> failwith "on_chunk failed"
        | _ -> ())
      ()
  in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  let parts = Option.map (List.map part_name) parts in
  (check (option string))
    "last part" (Some "error")
    (Option.bind parts (fun parts -> List.nth_opt parts (List.length parts - 1)));
  (check (option (list string))) "on_chunk sees every part" parts (Some (List.rev !chunks));
  (check bool) "usage fails with the provider error" true (failed_with_failure "provider down" result.usage);
  Lwt.return_unit

(* A custom model that ignores the abort signal: its stream sends one text part
   and then neither pushes nor closes. *)
let make_stalled_model () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-stalled"
    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      push (Some (Ai_provider.Stream_part.Text { text = "Hi" }));
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

(* Records the names of the spans that ended. *)
let make_exit_collector () =
  let names = Hashtbl.create 8 in
  let exited = ref [] in
  let next_id = ref 0 in
  let callbacks : unit Trace_core.Collector.Callbacks.t =
    Trace_core.Collector.Callbacks.make
      ~enter_span:(fun () ~__FUNCTION__:_ ~__FILE__:_ ~__LINE__:_ ~level:_ ~params:_ ~data:_ ~parent:_ name ->
        let id = !next_id in
        incr next_id;
        Hashtbl.replace names id name;
        Test_span id)
      ~exit_span:(fun () span ->
        match span with
        | Test_span id -> Option.iter (fun name -> exited := name :: !exited) (Hashtbl.find_opt names id)
        | _ -> ())
      ~add_data_to_span:(fun () _span _data -> ())
      ~message:(fun () ~level:_ ~params:_ ~data:_ ~span:_ _msg -> ())
      ~metric:(fun () ~level:_ ~params:_ ~data:_ _name _metric -> ())
      ()
  in
  Trace_core.Collector.C_some ((), callbacks), exited

(* The background job must finish after an abort even when the model never
   pushes again. Its root span ends only when the job does. *)
let test_abort_with_stalled_provider () =
  let collector, exited = make_exit_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    Lwt_main.run
      (let signal, (_ : unit Lwt.u) = Lwt.task () in
       let telemetry = Ai_core.Telemetry.create ~enabled:true () in
       let result =
         Ai_core.Stream_text.stream_text ~model:(make_stalled_model ()) ~prompt:"Hello" ~abort_signal:signal ~telemetry
           ()
       in
       let%lwt (_ : Ai_core.Text_stream_part.t list) =
         read_until
           (function
             | Ai_core.Text_stream_part.Text_delta _ -> true
             | _ -> false)
           result.full_stream ~acc:[]
       in
       Lwt.cancel signal;
       let%lwt parts = to_list_or_hang result.full_stream in
       let%lwt () = Lwt_unix.sleep 0.1 in
       (check (option (list string))) "parts after the abort" (Some [ "abort" ]) (Option.map (List.map part_name) parts);
       (check bool) "ai.streamText span ended" true (List.mem "ai.streamText" !exited);
       (check bool) "ai.streamText.doStream span ended" true (List.mem "ai.streamText.doStream" !exited);
       Lwt.return_unit))

let () =
  run "Stream_text"
    [
      ( "basic",
        [
          test_case "simple" `Quick test_simple_stream;
          test_case "full_events" `Quick test_full_stream_events;
          test_case "finish_reason" `Quick test_finish_reason;
          test_case "provider_metadata_surfaced" `Quick test_stream_surfaces_provider_metadata;
        ] );
      ( "tools",
        [
          test_case "tool_loop" `Quick test_tool_stream_loop;
          test_case "approval_stops_stream_loop" `Quick test_approval_stops_stream_loop;
          test_case "approved_tool_executes" `Quick test_approved_tool_executes_stream;
          test_case "denied_emits_output_denied" `Quick test_denied_tool_emits_output_denied;
          test_case "mixed_tools_safe_executes" `Quick test_mixed_tools_safe_executes_stream;
        ] );
      ( "callbacks",
        [
          test_case "on_chunk" `Quick test_on_chunk_callback;
          test_case "on_chunk_raises_on_finish" `Quick (run_lwt test_on_chunk_raises_on_finish);
          test_case "on_finish_raises" `Quick (run_lwt test_on_finish_raises);
          test_case "finish_step_before_on_step_finish" `Quick (run_lwt test_finish_step_before_on_step_finish);
          test_case "on_chunk_gets_error" `Quick (run_lwt test_on_chunk_gets_error);
        ] );
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
      ( "abort",
        [
          test_case "mid_stream" `Quick (run_lwt test_abort_mid_stream);
          test_case "before_start" `Quick (run_lwt test_abort_before_start);
          test_case "in_on_step_finish" `Quick (run_lwt test_abort_in_on_step_finish);
          test_case "during_tool" `Quick (run_lwt test_abort_during_tool);
          test_case "ui_stream" `Quick (run_lwt test_abort_ui_stream);
          test_case "on_chunk_raises" `Quick (run_lwt test_abort_on_chunk_raises);
          test_case "stops_reading_provider" `Quick (run_lwt test_abort_stops_reading_provider);
          test_case "after_pending_approvals" `Quick (run_lwt test_abort_after_pending_approvals);
          test_case "stalled_provider" `Quick test_abort_with_stalled_provider;
        ] );
    ]
