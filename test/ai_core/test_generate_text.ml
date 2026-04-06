open Melange_json.Primitives
open Alcotest

type query_args = { query : string } [@@json.allow_extra_fields] [@@deriving of_json]

(* Mock model that returns text *)
let make_text_model response_text =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-v1"

    let generate _opts =
      Lwt.return
        {
          Ai_provider.Generate_result.content = [ Ai_provider.Content.Text { text = response_text } ];
          finish_reason = Ai_provider.Finish_reason.Stop;
          usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
          warnings = [];
          provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = Some "r1"; model = Some "mock-v1"; headers = []; body = `Null };
        }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

(* Mock model that returns a tool call first, then text on second call *)
let make_tool_model () =
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-tool"

    let generate _opts =
      incr call_count;
      if !call_count = 1 then
        Lwt.return
          {
            Ai_provider.Generate_result.content =
              [
                Ai_provider.Content.Text { text = "Let me search." };
                Ai_provider.Content.Tool_call
                  {
                    tool_call_type = "function";
                    tool_call_id = "tc_1";
                    tool_name = "search";
                    args = {|{"query":"test"}|};
                  };
              ];
            finish_reason = Ai_provider.Finish_reason.Tool_calls;
            usage = { input_tokens = 10; output_tokens = 15; total_tokens = Some 25 };
            warnings = [];
            provider_metadata = Ai_provider.Provider_options.empty;
            request = { body = `Null };
            response = { id = Some "r1"; model = Some "mock-tool"; headers = []; body = `Null };
          }
      else
        Lwt.return
          {
            Ai_provider.Generate_result.content = [ Ai_provider.Content.Text { text = "Found the answer!" } ];
            finish_reason = Ai_provider.Finish_reason.Stop;
            usage = { input_tokens = 20; output_tokens = 10; total_tokens = Some 30 };
            warnings = [];
            provider_metadata = Ai_provider.Provider_options.empty;
            request = { body = `Null };
            response = { id = Some "r2"; model = Some "mock-tool"; headers = []; body = `Null };
          }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push None;
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
          let query = try (query_args_of_json args).query with _ -> "unknown" in
          Lwt.return (`String (Printf.sprintf "Results for: %s" query)));
    needs_approval = None;
  }

(* Tests *)

let test_simple_text () =
  let model = make_text_model "Hello world!" in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Say hello" ()) in
  (check string) "text" "Hello world!" result.text;
  (check string) "finish" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  (check int) "1 step" 1 (List.length result.steps);
  (check int) "no tool calls" 0 (List.length result.tool_calls)

let test_with_system () =
  let model = make_text_model "I am helpful." in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~system:"Be helpful" ~prompt:"Hello" ()) in
  (check string) "text" "I am helpful." result.text

let test_tool_loop () =
  let model = make_tool_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Search for test"
         ~tools:[ "search", search_tool ]
         ~max_steps:3 ())
  in
  (* Should have 2 steps: tool call + final answer *)
  (check int) "2 steps" 2 (List.length result.steps);
  (check string) "final text" "Let me search.\nFound the answer!" result.text;
  (check int) "1 tool call" 1 (List.length result.tool_calls);
  (check int) "1 tool result" 1 (List.length result.tool_results);
  (* Usage should be aggregated *)
  (check int) "total input" 30 result.usage.input_tokens;
  (check int) "total output" 25 result.usage.output_tokens

let test_tool_not_found () =
  let model = make_tool_model () in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Test" ~tools:[] ~max_steps:3 ()) in
  (* Unknown tool -> loop stops (matching upstream: break on unknown tool) *)
  (check int) "1 step" 1 (List.length result.steps);
  (check int) "1 tool call" 1 (List.length result.tool_calls);
  (check int) "0 tool results" 0 (List.length result.tool_results)

let test_max_steps_1 () =
  let model = make_tool_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Test" ~tools:[ "search", search_tool ] ~max_steps:1 ())
  in
  (* max_steps=1 means only 1 call, tool call returned but not executed *)
  (check int) "1 step" 1 (List.length result.steps);
  (check int) "1 tool call" 1 (List.length result.tool_calls);
  (check int) "0 tool results" 0 (List.length result.tool_results)

let test_on_step_finish () =
  let step_count = ref 0 in
  let model = make_tool_model () in
  let _result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Test"
         ~tools:[ "search", search_tool ]
         ~max_steps:3
         ~on_step_finish:(fun _step -> incr step_count)
         ())
  in
  (check int) "2 callbacks" 2 !step_count

let make_json_model json_str =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-json"

    let generate _opts =
      Lwt.return
        {
          Ai_provider.Generate_result.content = [ Text { text = json_str } ];
          finish_reason = Stop;
          usage = { input_tokens = 10; output_tokens = 20; total_tokens = Some 30 };
          warnings = [];
          provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = Some "r1"; model = Some "mock-json"; headers = []; body = `Null };
        }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let test_generate_with_object_output () =
  let schema =
    Yojson.Basic.from_string {|{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}|}
  in
  let output = Ai_core.Output.object_ ~name:"test" ~schema () in
  let model = make_json_model {|{"name":"Alice"}|} in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ~output ()) in
  match result.output with
  | Some (`Assoc [ ("name", `String "Alice") ]) -> ()
  | Some json -> fail (Printf.sprintf "unexpected: %s" (Yojson.Basic.to_string json))
  | None -> fail "expected output"

let test_generate_with_enum_output () =
  let output = Ai_core.Output.enum ~name:"sentiment" [ "positive"; "negative"; "neutral" ] in
  let model = make_json_model {|{"result":"positive"}|} in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ~output ()) in
  match result.output with
  | Some (`String "positive") -> ()
  | Some json -> fail (Printf.sprintf "unexpected: %s" (Yojson.Basic.to_string json))
  | None -> fail "expected output"

let test_generate_with_invalid_output () =
  let schema =
    Yojson.Basic.from_string {|{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}|}
  in
  let output = Ai_core.Output.object_ ~name:"test" ~schema () in
  let model = make_json_model "not valid json" in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ~output ()) in
  match result.output with
  | None -> ()
  | Some _ -> fail "expected None for invalid"

let test_generate_with_array_output () =
  let element_schema =
    Yojson.Basic.from_string {|{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}|}
  in
  let output = Ai_core.Output.array ~name:"cities" ~element_schema () in
  let model = make_json_model {|{"elements":[{"city":"Paris"},{"city":"London"}]}|} in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ~output ()) in
  match result.output with
  | Some (`List [ `Assoc _; `Assoc _ ]) -> ()
  | Some json -> fail (Printf.sprintf "unexpected: %s" (Yojson.Basic.to_string json))
  | None -> fail "expected output"

let test_generate_without_output () =
  let model = make_text_model "Hello!" in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ()) in
  match result.output with
  | None -> ()
  | Some _ -> fail "expected None when no output spec"

(* Mock model that always returns a single tool call for "dangerous_action" *)
let make_single_tool_call_model () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-approval"

    let generate _opts =
      Lwt.return
        {
          Ai_provider.Generate_result.content =
            [
              Ai_provider.Content.Text { text = "Let me check." };
              Ai_provider.Content.Tool_call
                {
                  tool_call_type = "function";
                  tool_call_id = "tc_1";
                  tool_name = "dangerous_action";
                  args = {|{"target":"prod"}|};
                };
            ];
          finish_reason = Ai_provider.Finish_reason.Tool_calls;
          usage = { input_tokens = 10; output_tokens = 15; total_tokens = Some 25 };
          warnings = [];
          provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = Some "r1"; model = Some "mock-approval"; headers = []; body = `Null };
        }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let approval_tool : Ai_core.Core_tool.t =
  Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
    ~parameters:(`Assoc [ "type", `String "object" ])
    ~execute:(fun _ -> Lwt.return (`String "executed"))
    ()

let test_approval_stops_loop () =
  let model = make_single_tool_call_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Do it"
         ~tools:[ "dangerous_action", approval_tool ]
         ~max_steps:3 ())
  in
  (check int) "1 step" 1 (List.length result.steps);
  (check int) "1 tool call" 1 (List.length result.tool_calls);
  (check int) "0 tool results" 0 (List.length result.tool_results)

let test_no_approval_executes_normally () =
  let model = make_tool_model () in
  let no_approval_search_tool : Ai_core.Core_tool.t =
    Ai_core.Core_tool.create ~description:"Search"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun args ->
        let query = try (query_args_of_json args).query with _ -> "unknown" in
        Lwt.return (`String (Printf.sprintf "Results for: %s" query)))
      ()
  in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Search for test"
         ~tools:[ "search", no_approval_search_tool ]
         ~max_steps:3 ())
  in
  (check int) "2 steps" 2 (List.length result.steps);
  (check int) "1 tool call" 1 (List.length result.tool_calls);
  (check int) "1 tool result" 1 (List.length result.tool_results)

let test_dynamic_approval_conditional () =
  let dynamic_tool : Ai_core.Core_tool.t =
    Ai_core.Core_tool.create
      ~needs_approval:(fun args ->
        let target = try Yojson.Basic.Util.member "target" args |> Yojson.Basic.Util.to_string with _ -> "" in
        Lwt.return (String.equal target "prod"))
      ~description:"Dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ -> Lwt.return (`String "executed"))
      ()
  in
  let model = make_single_tool_call_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Do it"
         ~tools:[ "dangerous_action", dynamic_tool ]
         ~max_steps:3 ())
  in
  (check int) "1 step" 1 (List.length result.steps);
  (check int) "1 tool call" 1 (List.length result.tool_calls);
  (check int) "0 tool results" 0 (List.length result.tool_results)

let test_approved_tool_executes () =
  (* Model returns tool call for "dangerous_action" on first call, then text on second *)
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-approval-exec"

    let generate _opts =
      incr call_count;
      match !call_count with
      | 1 ->
        Lwt.return
          {
            Ai_provider.Generate_result.content =
              [
                Ai_provider.Content.Text { text = "Let me check." };
                Ai_provider.Content.Tool_call
                  {
                    tool_call_type = "function";
                    tool_call_id = "tc_1";
                    tool_name = "dangerous_action";
                    args = {|{"target":"prod"}|};
                  };
              ];
            finish_reason = Ai_provider.Finish_reason.Tool_calls;
            usage = { input_tokens = 10; output_tokens = 15; total_tokens = Some 25 };
            warnings = [];
            provider_metadata = Ai_provider.Provider_options.empty;
            request = { body = `Null };
            response = { id = Some "r1"; model = Some "mock-approval-exec"; headers = []; body = `Null };
          }
      | _ ->
        Lwt.return
          {
            Ai_provider.Generate_result.content = [ Ai_provider.Content.Text { text = "Done!" } ];
            finish_reason = Ai_provider.Finish_reason.Stop;
            usage = { input_tokens = 20; output_tokens = 5; total_tokens = Some 25 };
            warnings = [];
            provider_metadata = Ai_provider.Provider_options.empty;
            request = { body = `Null };
            response = { id = Some "r2"; model = Some "mock-approval-exec"; headers = []; body = `Null };
          }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  let model = (module M : Ai_provider.Language_model.S) in
  (* Tool that always needs approval *)
  let tool =
    Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ -> Lwt.return (`String "executed"))
      ()
  in
  (* Pass tc_1 as pre-approved pending approval — should execute directly *)
  let pending : Ai_core.Generate_text_result.pending_tool_approval =
    {
      tool_call_id = "tc_1";
      tool_name = "dangerous_action";
      args = `Assoc [ "target", `String "prod" ];
      approved = true;
    }
  in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Do it"
         ~tools:[ "dangerous_action", tool ]
         ~pending_tool_approvals:[ pending ] ~max_steps:3 ())
  in
  (* Initial step executes tool, then LLM step — 3 steps total *)
  (check bool) "has tool results" true (List.length result.tool_results > 0);
  match result.tool_results with
  | tr :: _ -> (check bool) "not error" false tr.is_error
  | [] -> Alcotest.fail "expected at least one tool result"

(* Mock model that returns two tool calls — one needing approval, one not *)
let make_mixed_tool_call_model () =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-mixed"

    let generate _opts =
      Lwt.return
        {
          Ai_provider.Generate_result.content =
            [
              Ai_provider.Content.Text { text = "Let me do both." };
              Ai_provider.Content.Tool_call
                {
                  tool_call_type = "function";
                  tool_call_id = "tc_safe";
                  tool_name = "safe_action";
                  args = {|{"query":"test"}|};
                };
              Ai_provider.Content.Tool_call
                {
                  tool_call_type = "function";
                  tool_call_id = "tc_danger";
                  tool_name = "dangerous_action";
                  args = {|{"target":"prod"}|};
                };
            ];
          finish_reason = Ai_provider.Finish_reason.Tool_calls;
          usage = { input_tokens = 10; output_tokens = 20; total_tokens = Some 30 };
          warnings = [];
          provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = Some "r1"; model = Some "mock-mixed"; headers = []; body = `Null };
        }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let test_mixed_tools_safe_executes () =
  let model = make_mixed_tool_call_model () in
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
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Do both"
         ~tools:[ "safe_action", safe_tool; "dangerous_action", dangerous_tool ]
         ~max_steps:3 ())
  in
  (* Safe tool executes, dangerous needs approval — loop stops after 1 step *)
  (check int) "1 step" 1 (List.length result.steps);
  (check int) "2 tool calls" 2 (List.length result.tool_calls);
  (* Safe tool executed, so 1 tool result *)
  (check int) "1 tool result" 1 (List.length result.tool_results);
  match result.tool_results with
  | tr :: _ ->
    (check string) "safe tool result" {|"safe result"|} (Yojson.Basic.to_string tr.result);
    (check bool) "not error" false tr.is_error
  | [] -> Alcotest.fail "expected 1 tool result"

let test_prompt_and_messages_conflict () =
  let model = make_text_model "test" in
  let raised = ref false in
  (try
     ignore
       (Lwt_main.run
          (Ai_core.Generate_text.generate_text ~model ~prompt:"a"
             ~messages:[ Ai_provider.Prompt.User { content = [] } ]
             ())
         : Ai_core.Generate_text_result.t)
   with Failure _ -> raised := true);
  (check bool) "raises" true !raised

let () =
  run "Generate_text"
    [
      "basic", [ test_case "simple_text" `Quick test_simple_text; test_case "with_system" `Quick test_with_system ];
      ( "tools",
        [
          test_case "tool_loop" `Quick test_tool_loop;
          test_case "tool_not_found" `Quick test_tool_not_found;
          test_case "max_steps_1" `Quick test_max_steps_1;
          test_case "on_step_finish" `Quick test_on_step_finish;
        ] );
      ( "approval",
        [
          test_case "approval_stops_loop" `Quick test_approval_stops_loop;
          test_case "no_approval_executes_normally" `Quick test_no_approval_executes_normally;
          test_case "dynamic_approval_conditional" `Quick test_dynamic_approval_conditional;
          test_case "approved_tool_executes" `Quick test_approved_tool_executes;
          test_case "mixed_tools_safe_executes" `Quick test_mixed_tools_safe_executes;
        ] );
      "errors", [ test_case "prompt_and_messages" `Quick test_prompt_and_messages_conflict ];
      ( "output",
        [
          test_case "object_output" `Quick test_generate_with_object_output;
          test_case "enum_output" `Quick test_generate_with_enum_output;
          test_case "array_output" `Quick test_generate_with_array_output;
          test_case "invalid_output" `Quick test_generate_with_invalid_output;
          test_case "no_output" `Quick test_generate_without_output;
        ] );
    ]
