open Melange_json.Primitives
open Alcotest

type query_args = { query : string } [@@json.allow_extra_fields] [@@deriving of_json]

module Mock = Ai_mock.Language_model

(* Token counts whose total is their sum. *)
let tokens input_tokens output_tokens : Ai_provider.Usage.t =
  { input_tokens; output_tokens; total_tokens = Some (input_tokens + output_tokens) }

(* [result] with a response that reports [id] and [model], as a provider's does. *)
let with_response ~id ~model (result : Ai_provider.Generate_result.t) =
  { result with response = { id = Some id; model = Some model; headers = []; body = `Null } }

let tool_call ?(tool_name = "search") ?(args = {|{"query":"test"}|}) tool_call_id =
  Ai_provider.Content.Tool_call { tool_call_type = "function"; tool_call_id; tool_name; args }

(* Mock model that returns text *)
let make_text_model response_text =
  fst
    (Mock.create ~provider:"mock" ~model_id:"mock-v1"
       ~generate:
         (Return
            (with_response ~id:"r1" ~model:"mock-v1"
               (Mock.generate_result ~usage:(tokens 10 5) [ Text { text = response_text } ])))
       ())

(* Mock model that returns a tool call first, then text on second call *)
let make_tool_model () =
  fst
    (Mock.create
       ~generate:
         (Sequence
            [
              with_response ~id:"r1" ~model:"actual-step-1"
                (Mock.generate_result ~finish_reason:Tool_calls ~usage:(tokens 10 15)
                   [ Text { text = "Let me search." }; tool_call "tc_1" ]);
              with_response ~id:"r2" ~model:"actual-step-2"
                (Mock.generate_result ~usage:(tokens 20 10) [ Text { text = "Found the answer!" } ]);
            ])
       ())

let search_tool : Ai_core.Core_tool.t =
  {
    description = Some "Search";
    parameters = `Assoc [ "type", `String "object" ];
    execute =
      Some
        (fun args _ ->
          let query = try (query_args_of_json args).query with _ -> "unknown" in
          Lwt.return (`String (Printf.sprintf "Results for: %s" query)));
    needs_approval = None;
    provider_options = Ai_provider.Provider_options.empty;
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
  (check (list (option string)))
    "actual model per step"
    [ Some "actual-step-1"; Some "actual-step-2" ]
    (List.map (fun (step : Ai_core.Generate_text_result.step) -> step.response_model) result.steps);
  (check (option string)) "aggregate keeps final model" (Some "actual-step-2") result.response.model;
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
  fst (Mock.create ~generate:(Return (Mock.generate_result ~usage:(tokens 10 20) [ Text { text = json_str } ])) ())

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
  fst
    (Mock.create
       ~generate:
         (Return
            (Mock.generate_result ~finish_reason:Tool_calls ~usage:(tokens 10 15)
               [
                 Text { text = "Let me check." };
                 tool_call ~tool_name:"dangerous_action" ~args:{|{"target":"prod"}|} "tc_1";
               ]))
       ())

let approval_tool : Ai_core.Core_tool.t =
  Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
    ~parameters:(`Assoc [ "type", `String "object" ])
    ~execute:(fun _ _ -> Lwt.return (`String "executed"))
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
      ~execute:(fun args _ ->
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
      ~execute:(fun _ _ -> Lwt.return (`String "executed"))
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
  let model, (_ : Mock.t) =
    Mock.create
      ~generate:
        (Sequence
           [
             Mock.generate_result ~finish_reason:Tool_calls ~usage:(tokens 10 15)
               [
                 Text { text = "Let me check." };
                 tool_call ~tool_name:"dangerous_action" ~args:{|{"target":"prod"}|} "tc_1";
               ];
             Mock.generate_result ~usage:(tokens 20 5) [ Text { text = "Done!" } ];
           ])
      ()
  in
  (* Tool that always needs approval *)
  let tool =
    Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ _ -> Lwt.return (`String "executed"))
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
  fst
    (Mock.create
       ~generate:
         (Return
            (Mock.generate_result ~finish_reason:Tool_calls ~usage:(tokens 10 20)
               [
                 Text { text = "Let me do both." };
                 tool_call ~tool_name:"safe_action" "tc_safe";
                 tool_call ~tool_name:"dangerous_action" ~args:{|{"target":"prod"}|} "tc_danger";
               ]))
       ())

let test_mixed_tools_safe_executes () =
  let model = make_mixed_tool_call_model () in
  let safe_tool =
    Ai_core.Core_tool.create ~description:"Safe"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ _ -> Lwt.return (`String "safe result"))
      ()
  in
  let dangerous_tool =
    Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ _ -> Lwt.return (`String "dangerous result"))
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

(* Mock model that always returns a tool call, for testing stop_when *)
let make_multi_step_tool_model () =
  let calls = ref 0 in
  fst
    (Mock.create
       ~generate:
         (Respond
            (fun (_ : Ai_provider.Call_options.t) ->
              incr calls;
              Lwt.return
                (Mock.generate_result ~finish_reason:Tool_calls ~usage:(tokens 10 10)
                   [
                     Text { text = Printf.sprintf "Step %d" !calls };
                     tool_call ~args:(Printf.sprintf {|{"query":"step%d"}|} !calls) (Printf.sprintf "tc_%d" !calls);
                   ])))
       ())

let test_stop_when_step_count () =
  let model = make_multi_step_tool_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Go"
         ~tools:[ "search", search_tool ]
         ~max_steps:10
         ~stop_when:[ Ai_core.Stop_condition.step_count_is 3 ]
         ())
  in
  (* Should stop after 3 steps even though max_steps is 10 *)
  (check int) "3 steps" 3 (List.length result.steps)

let test_stop_when_has_tool_call () =
  (* Model that calls "search" on step 1, "done_tool" on step 2 *)
  let step tool_name tool_call_id =
    Mock.generate_result ~finish_reason:Tool_calls ~usage:(tokens 10 5) [ tool_call ~tool_name tool_call_id ]
  in
  let model, (_ : Mock.t) = Mock.create ~generate:(Sequence [ step "search" "tc_1"; step "done_tool" "tc_2" ]) () in
  let done_tool : Ai_core.Core_tool.t =
    Ai_core.Core_tool.create ~description:"Done"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ _ -> Lwt.return (`String "done"))
      ()
  in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Go"
         ~tools:[ "search", search_tool; "done_tool", done_tool ]
         ~max_steps:10
         ~stop_when:[ Ai_core.Stop_condition.has_tool_call "done_tool" ]
         ())
  in
  (* Should stop after step 2 when done_tool is called *)
  (check int) "2 steps" 2 (List.length result.steps)

let test_stop_when_max_steps_still_limits () =
  let model = make_multi_step_tool_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Go"
         ~tools:[ "search", search_tool ]
         ~max_steps:2
         ~stop_when:[ Ai_core.Stop_condition.step_count_is 10 ]
         ())
  in
  (* max_steps=2 should still be the hard limit *)
  (check int) "2 steps" 2 (List.length result.steps)

let test_stop_when_or_semantics () =
  let model = make_multi_step_tool_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Go"
         ~tools:[ "search", search_tool ]
         ~max_steps:10
         ~stop_when:[ Ai_core.Stop_condition.step_count_is 100; Ai_core.Stop_condition.step_count_is 2 ]
         ())
  in
  (* OR semantics: step_count_is 2 should fire first *)
  (check int) "2 steps" 2 (List.length result.steps)

let test_stop_when_empty_conditions () =
  (* Empty stop_when list should never stop — behaves like no stop_when *)
  let model = make_tool_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Go"
         ~tools:[ "search", search_tool ]
         ~max_steps:5 ~stop_when:[] ())
  in
  (* make_tool_model returns tool call on first call, text on second *)
  (check int) "2 steps" 2 (List.length result.steps)

let test_stop_when_custom_predicate () =
  (* Custom lambda: stop when any step has reasoning text *)
  let model = make_multi_step_tool_model () in
  let step_num = ref 0 in
  let custom_condition ~(steps : Ai_core.Generate_text_result.step list) =
    let _ = steps in
    incr step_num;
    Lwt.return (!step_num >= 2)
  in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Go"
         ~tools:[ "search", search_tool ]
         ~max_steps:10 ~stop_when:[ custom_condition ] ())
  in
  (check int) "2 steps" 2 (List.length result.steps)

let test_stop_when_not_set () =
  (* Without stop_when, the loop continues until max_steps or no tool calls *)
  let model = make_tool_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Go" ~tools:[ "search", search_tool ] ~max_steps:5 ())
  in
  (* make_tool_model returns tool call on first call, text on second *)
  (check int) "2 steps" 2 (List.length result.steps)

(* Mock model that fails N times with retryable error, then succeeds *)
let make_retry_model ~fail_count =
  let call_count = ref 0 in
  let respond (_ : Ai_provider.Call_options.t) =
    incr call_count;
    if !call_count <= fail_count then
      Lwt.fail
        (Ai_provider.Provider_error.Provider_error
           {
             provider = "mock";
             kind = Api_error { status = 429; body = "rate limited" };
             is_retryable = true;
             retry_after_s = None;
           })
    else Lwt.return (Mock.generate_result ~usage:(tokens 10 5) [ Text { text = "recovered" } ])
  in
  call_count, fst (Mock.create ~generate:(Respond respond) ())

let test_generate_retries_on_retryable_error () =
  let call_count, model = make_retry_model ~fail_count:1 in
  let result =
    Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~max_retries:2 ~max_retry_delay_ms:0 ~prompt:"test" ())
  in
  (check string) "recovered" "recovered" result.text;
  (check int) "called twice" 2 !call_count

(* ---- Telemetry test helpers ---- *)

type Trace_core.span += Test_span of int

(** Minimal trace collector that records span names and data for assertions. *)
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

let test_telemetry_spans () =
  let collector, get_span_names, _get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~function_id:"test-fn" () in
    let _result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ()) in
    let names = get_span_names () in
    (check bool) "has root" true (List.mem "ai.generateText" names);
    (check bool) "has step" true (List.mem "ai.generateText.doGenerate" names))

let test_telemetry_tool_spans () =
  let collector, get_span_names, _get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_tool_model () in
    let telemetry = Ai_core.Telemetry.create ~enabled:true () in
    let _result =
      Lwt_main.run
        (Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
           ~tools:[ "search", search_tool ]
           ~max_steps:3 ~telemetry ())
    in
    let names = get_span_names () in
    (check bool) "has root" true (List.mem "ai.generateText" names);
    (check bool) "has tool call" true (List.mem "ai.toolCall" names);
    let step_count = List.length (List.filter (String.equal "ai.generateText.doGenerate") names) in
    (check int) "2 step spans" 2 step_count)

let test_telemetry_root_attributes () =
  let collector, _get_span_names, get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~function_id:"my-fn" () in
    let _result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ()) in
    let data = get_span_data "ai.generateText" in
    (check string) "operation.name" "ai.generateText my-fn"
      (match List.assoc_opt "operation.name" data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "ai.model.provider" "mock"
      (match List.assoc_opt "ai.model.provider" data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "ai.model.id" "mock-v1"
      (match List.assoc_opt "ai.model.id" data with
      | Some (`String s) -> s
      | _ -> ""))

let test_telemetry_disabled_no_spans () =
  let collector, get_span_names, _get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:false () in
    let _result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ()) in
    let names = get_span_names () in
    (check int) "no spans when disabled" 0 (List.length names))

let test_telemetry_integration_callbacks () =
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
  let model = make_tool_model () in
  let telemetry = Ai_core.Telemetry.create ~enabled:true ~integrations:[ integration ] () in
  let _result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
         ~tools:[ "search", search_tool ]
         ~max_steps:3 ~telemetry ())
  in
  let evts = List.rev !events in
  (check bool) "has start" true (List.exists (fun s -> String.starts_with ~prefix:"start:" s) evts);
  (check bool) "has tool_start" true (List.exists (fun s -> String.starts_with ~prefix:"tool_start:" s) evts);
  (check bool) "has tool_finish" true (List.exists (fun s -> String.starts_with ~prefix:"tool_finish:" s) evts);
  (check bool) "has step" true (List.exists (fun s -> String.starts_with ~prefix:"step:" s) evts);
  (check bool) "has finish" true (List.exists (fun s -> String.starts_with ~prefix:"finish:" s) evts)

let test_telemetry_no_outputs () =
  let collector, _get_span_names, get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_model "Secret response" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~record_outputs:false () in
    let _result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ()) in
    (* Root span should NOT have ai.response.text when record_outputs=false *)
    let root_data = get_span_data "ai.generateText" in
    (check bool) "no response text on root" true (not (List.mem_assoc "ai.response.text" root_data));
    (* Step span should NOT have ai.response.text either *)
    let step_data = get_span_data "ai.generateText.doGenerate" in
    (check bool) "no response text on step" true (not (List.mem_assoc "ai.response.text" step_data));
    (* But usage (Always) should still be present on step span *)
    (check bool) "has usage on step" true (List.mem_assoc "ai.usage.inputTokens" step_data))

let test_telemetry_no_inputs () =
  let collector, _get_span_names, get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~record_inputs:false () in
    let _result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ()) in
    (* Root span should NOT have ai.prompt when record_inputs=false *)
    let root_data = get_span_data "ai.generateText" in
    (check bool) "no prompt on root" true (not (List.mem_assoc "ai.prompt" root_data));
    (* Step span should NOT have ai.prompt.messages *)
    let step_data = get_span_data "ai.generateText.doGenerate" in
    (check bool) "no prompt messages on step" true (not (List.mem_assoc "ai.prompt.messages" step_data)))

let test_telemetry_step_response_attrs () =
  let collector, _get_span_names, get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true () in
    let _result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ()) in
    let step_data = get_span_data "ai.generateText.doGenerate" in
    (* Should have response attributes from the plan *)
    (check bool) "has ai.response.text" true (List.mem_assoc "ai.response.text" step_data);
    (check bool) "has ai.response.reasoning" true (List.mem_assoc "ai.response.reasoning" step_data);
    (check bool) "has ai.response.finishReason" true (List.mem_assoc "ai.response.finishReason" step_data);
    (check bool) "has ai.usage.inputTokens" true (List.mem_assoc "ai.usage.inputTokens" step_data);
    (check bool) "has gen_ai.usage.input_tokens" true (List.mem_assoc "gen_ai.usage.input_tokens" step_data);
    (* Should have prompt request attrs *)
    (check bool) "has ai.prompt.messages" true (List.mem_assoc "ai.prompt.messages" step_data);
    (check bool) "has gen_ai.system" true (List.mem_assoc "gen_ai.system" step_data);
    (check bool) "has gen_ai.request.model" true (List.mem_assoc "gen_ai.request.model" step_data))

let test_telemetry_attribute_values () =
  let collector, _get_span_names, get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_text_model "Hello!" in
    let telemetry =
      Ai_core.Telemetry.create ~enabled:true ~function_id:"my-fn" ~metadata:[ "env", `String "test" ] ()
    in
    let _result =
      Lwt_main.run
        (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ~max_output_tokens:100 ~temperature:0.5 ())
    in
    (* Root span: verify operation name includes function_id *)
    let root_data = get_span_data "ai.generateText" in
    (check string) "operation.name value" "ai.generateText my-fn"
      (match List.assoc_opt "operation.name" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "ai.operationId value" "ai.generateText"
      (match List.assoc_opt "ai.operationId" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "resource.name value" "my-fn"
      (match List.assoc_opt "resource.name" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "ai.telemetry.functionId value" "my-fn"
      (match List.assoc_opt "ai.telemetry.functionId" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (* Root span: final response attribute values *)
    (check string) "root ai.response.text" "Hello!"
      (match List.assoc_opt "ai.response.text" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "root ai.response.finishReason" "stop"
      (match List.assoc_opt "ai.response.finishReason" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (check int) "root ai.usage.inputTokens" 10
      (match List.assoc_opt "ai.usage.inputTokens" root_data with
      | Some (`Int n) -> n
      | _ -> 0);
    (check int) "root ai.usage.outputTokens" 5
      (match List.assoc_opt "ai.usage.outputTokens" root_data with
      | Some (`Int n) -> n
      | _ -> 0);
    (* Step span: verify concrete attribute values *)
    let step_data = get_span_data "ai.generateText.doGenerate" in
    (check string) "step ai.response.text" "Hello!"
      (match List.assoc_opt "ai.response.text" step_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "step ai.response.finishReason" "stop"
      (match List.assoc_opt "ai.response.finishReason" step_data with
      | Some (`String s) -> s
      | _ -> "");
    (check int) "step ai.usage.inputTokens" 10
      (match List.assoc_opt "ai.usage.inputTokens" step_data with
      | Some (`Int n) -> n
      | _ -> 0);
    (check int) "step ai.usage.outputTokens" 5
      (match List.assoc_opt "ai.usage.outputTokens" step_data with
      | Some (`Int n) -> n
      | _ -> 0);
    (check string) "step gen_ai.system" "mock"
      (match List.assoc_opt "gen_ai.system" step_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "step gen_ai.request.model" "mock-v1"
      (match List.assoc_opt "gen_ai.request.model" step_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "step gen_ai.response.finish_reasons" "stop"
      (match List.assoc_opt "gen_ai.response.finish_reasons" step_data with
      | Some (`String s) -> s
      | _ -> "");
    (check int) "step gen_ai.usage.input_tokens" 10
      (match List.assoc_opt "gen_ai.usage.input_tokens" step_data with
      | Some (`Int n) -> n
      | _ -> 0);
    (check int) "step gen_ai.usage.output_tokens" 5
      (match List.assoc_opt "gen_ai.usage.output_tokens" step_data with
      | Some (`Int n) -> n
      | _ -> 0);
    (* Step span: response.id and response.model from mock *)
    (check string) "step ai.response.id" "r1"
      (match List.assoc_opt "ai.response.id" step_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "step ai.response.model" "mock-v1"
      (match List.assoc_opt "ai.response.model" step_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "step gen_ai.response.id" "r1"
      (match List.assoc_opt "gen_ai.response.id" step_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "step gen_ai.response.model" "mock-v1"
      (match List.assoc_opt "gen_ai.response.model" step_data with
      | Some (`String s) -> s
      | _ -> "");
    (* Base attributes: model info and metadata *)
    (check string) "ai.model.provider" "mock"
      (match List.assoc_opt "ai.model.provider" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "ai.model.id" "mock-v1"
      (match List.assoc_opt "ai.model.id" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "metadata.env" "test"
      (match List.assoc_opt "ai.telemetry.metadata.env" root_data with
      | Some (`String s) -> s
      | _ -> ""))

let test_generate_no_retry_on_non_retryable () =
  let model =
    fst
      (Mock.create
         ~generate:
           (Respond
              (fun (_ : Ai_provider.Call_options.t) ->
                Lwt.fail
                  (Ai_provider.Provider_error.Provider_error
                     {
                       provider = "mock";
                       kind = Api_error { status = 400; body = "bad" };
                       is_retryable = false;
                       retry_after_s = None;
                     })))
         ())
  in
  Lwt_main.run
    (Lwt.catch
       (fun () ->
         let%lwt _ = Ai_core.Generate_text.generate_text ~model ~prompt:"test" () in
         Alcotest.fail "expected error")
       (function
         | Ai_provider.Provider_error.Provider_error _ -> Lwt.return_unit
         | exn -> Lwt.fail exn))

(* A response that asks for the [search] tool once per id in [tool_call_ids]. *)
let search_call_result ?(tool_call_ids = [ "tc_1" ]) () =
  Mock.generate_result ~finish_reason:Tool_calls ~usage:(tokens 10 5)
    (List.map (tool_call ~args:{|{"query":"x"}|}) tool_call_ids)

(* Every call gets [search_call_result ?tool_call_ids ()]. *)
let make_abort_tool_model ?tool_call_ids () = Mock.create ~generate:(Return (search_call_result ?tool_call_ids ())) ()

let model_calls mock = List.length (Mock.generate_calls mock)

(* Runs a [generate_text] call and names its outcome: "finished", "aborted"
   for [Aborted], or the exception. *)
let generate_outcome run =
  Lwt_main.run
    (Lwt.catch
       (fun () ->
         let%lwt (_ : Ai_core.Generate_text_result.t) = run () in
         Lwt.return "finished")
       (function
         | Ai_provider.Abort_signal.Aborted _ -> Lwt.return "aborted"
         | exn -> Lwt.return (Printexc.to_string exn)))

(* A [search] tool that counts its runs in [runs] and fires the signal from
   [abort] when given one. *)
let counting_search_tool ?abort runs =
  {
    search_tool with
    execute =
      Some
        (fun (_ : Yojson.Basic.t) _ ->
          incr runs;
          Option.iter (fun abort -> abort ()) abort;
          Lwt.return (`String "results"));
  }

(* The tool fires the signal, so the second step never starts. *)
let test_abort_between_steps () =
  let model, mock = make_abort_tool_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let tool = counting_search_tool ~abort (ref 0) in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", tool ]
        ~max_steps:3 ~abort_signal:signal ())
  in
  (check string) "outcome" "aborted" outcome;
  (check int) "one model call" 1 (model_calls mock);
  (check (list bool))
    "the call got the signal" [ true ]
    (List.map
       (fun (options : Ai_provider.Call_options.t) -> Option.is_some options.abort_signal)
       (Mock.generate_calls mock))

(* The first of two tool calls fires the signal, so the second never runs. *)
let test_abort_between_tools () =
  let model, mock = make_abort_tool_model ~tool_call_ids:[ "tc_1"; "tc_2" ] () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let runs = ref 0 in
  let tool = counting_search_tool ~abort runs in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", tool ]
        ~max_steps:3 ~abort_signal:signal ())
  in
  (check string) "outcome" "aborted" outcome;
  (check int) "one tool run" 1 !runs;
  (check int) "one model call" 1 (model_calls mock)

(* An approved pending tool does not run once the signal has fired. *)
let test_abort_before_pending_approval () =
  let model, mock = make_abort_tool_model () in
  let runs = ref 0 in
  let tool = counting_search_tool runs in
  let pending : Ai_core.Generate_text_result.pending_tool_approval =
    { tool_call_id = "tc_0"; tool_name = "search"; args = `Assoc []; approved = true }
  in
  let aborted_steps = ref None in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", tool ]
        ~pending_tool_approvals:[ pending ] ~max_steps:3
        ~abort_signal:(Ai_provider.Abort_signal.of_promise Lwt.return_unit)
        ~on_abort:(fun ~steps -> aborted_steps := Some (List.length steps))
        ())
  in
  (check string) "outcome" "aborted" outcome;
  (check int) "tool never runs" 0 !runs;
  (check int) "model never called" 0 (model_calls mock);
  (* As in [stream_text], no step is recorded. *)
  (check (option int)) "on_abort steps" (Some 0) !aborted_steps

let ids_of_calls = List.map (fun (tc : Ai_core.Generate_text_result.tool_call) -> tc.tool_call_id)
let ids_of_results = List.map (fun (tr : Ai_core.Generate_text_result.tool_result) -> tr.tool_call_id)

(* Checks that on_abort got one step with [usage], [tool_calls] and the
   results of [tool_results]. *)
let check_aborted_step ~(usage : Ai_provider.Usage.t) ~tool_calls ~tool_results
  (steps : Ai_core.Generate_text_result.step list option) =
  match steps with
  | Some [ step ] ->
    (check int) "input tokens" usage.input_tokens step.usage.input_tokens;
    (check int) "output tokens" usage.output_tokens step.usage.output_tokens;
    (check (option int)) "total tokens" usage.total_tokens step.usage.total_tokens;
    (check (list string)) "tool calls" tool_calls (ids_of_calls step.tool_calls);
    (check (list string)) "tool results" tool_results (ids_of_results step.tool_results)
  | Some steps -> failf "expected one step, got %d" (List.length steps)
  | None -> fail "on_abort was not called"

(* Pauses when [pause], so the code after it runs inside an Lwt callback, as
   it does after the real I/O of a provider or a tool. *)
let maybe_pause pause =
  match pause with
  | true -> Lwt.pause ()
  | false -> Lwt.return_unit

(* Runs a search where the tool of [abort_in] fires the signal and returns.
   With [~pause:true], the model and each tool pause first. Checks that the
   call fails with [Aborted] and that on_step_finish is not called. Returns
   the steps on_abort got, the tools that ran and the model call count. *)
let run_abort_in_tool ?pending_tool_approvals ?stop_when ?telemetry ?(pause = false) ~abort_in () =
  let model, mock =
    Mock.create
      ~generate:
        (Respond
           (fun (_ : Ai_provider.Call_options.t) ->
             let%lwt () = maybe_pause pause in
             Lwt.return (search_call_result ~tool_call_ids:[ "tc_1"; "tc_2" ] ())))
      ()
  in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let ran = ref [] in
  let tool =
    {
      search_tool with
      execute =
        Some
          (fun (_ : Yojson.Basic.t) (options : Ai_core.Core_tool.execute_options) ->
            ran := options.tool_call_id :: !ran;
            let%lwt () = maybe_pause pause in
            if String.equal options.tool_call_id abort_in then abort ();
            Lwt.return (`String "results"));
    }
  in
  let aborted_steps = ref None in
  let step_finished = ref false in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", tool ]
        ?pending_tool_approvals ?stop_when ?telemetry ~max_steps:3 ~abort_signal:signal
        ~on_step_finish:(fun (_ : Ai_core.Generate_text_result.step) -> step_finished := true)
        ~on_abort:(fun ~steps -> aborted_steps := Some steps)
        ())
  in
  (check string) "outcome" "aborted" outcome;
  (check bool) "on_step_finish not called" false !step_finished;
  !aborted_steps, List.rev !ran, model_calls mock

(* The first of two tool calls fires the signal, then returns. The step keeps
   the model's usage and both calls, but no result: a result counts only if
   its tool returned before the signal fired. The second tool never runs. *)
let test_abort_in_tool_batch_keeps_step () =
  let aborted_steps, ran, calls = run_abort_in_tool ~abort_in:"tc_1" () in
  check_aborted_step
    ~usage:{ input_tokens = 10; output_tokens = 5; total_tokens = Some 15 }
    ~tool_calls:[ "tc_1"; "tc_2" ] ~tool_results:[] aborted_steps;
  (check (list string)) "tools that ran" [ "tc_1" ] ran;
  (check int) "one model call" 1 calls

(* The second of two tool calls fires the signal. The first tool's result is
   kept. *)
let test_abort_in_second_tool_keeps_first_result () =
  let aborted_steps, ran, calls = run_abort_in_tool ~abort_in:"tc_2" () in
  check_aborted_step
    ~usage:{ input_tokens = 10; output_tokens = 5; total_tokens = Some 15 }
    ~tool_calls:[ "tc_1"; "tc_2" ] ~tool_results:[ "tc_1" ] aborted_steps;
  (check (list string)) "tools that ran" [ "tc_1"; "tc_2" ] ran;
  (check int) "one model call" 1 calls

(* As [test_abort_in_tool_batch_keeps_step] and
   [test_abort_in_second_tool_keeps_first_result], with the model and the
   tools pausing first, so the abort comes from inside an Lwt callback. *)
let test_abort_in_tool_at_depth_1 () =
  let usage : Ai_provider.Usage.t = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 } in
  let aborted_steps, ran, (_ : int) = run_abort_in_tool ~pause:true ~abort_in:"tc_1" () in
  check_aborted_step ~usage ~tool_calls:[ "tc_1"; "tc_2" ] ~tool_results:[] aborted_steps;
  (check (list string)) "tools that ran" [ "tc_1" ] ran;
  let aborted_steps, ran, (_ : int) = run_abort_in_tool ~pause:true ~abort_in:"tc_2" () in
  check_aborted_step ~usage ~tool_calls:[ "tc_1"; "tc_2" ] ~tool_results:[ "tc_1" ] aborted_steps;
  (check (list string)) "tools that ran" [ "tc_1"; "tc_2" ] ran

(* The abort comes from the last tool of a step that would end the call, as
   [stop_when] is met. The call still fails, and on_abort gets the step once,
   with no on_step_finish. *)
let test_abort_in_last_tool_with_stop_when () =
  let aborted_steps, (_ : string list), (_ : int) =
    run_abort_in_tool ~stop_when:[ Ai_core.Stop_condition.step_count_is 1 ] ~abort_in:"tc_2" ()
  in
  check_aborted_step
    ~usage:{ input_tokens = 10; output_tokens = 5; total_tokens = Some 15 }
    ~tool_calls:[ "tc_1"; "tc_2" ] ~tool_results:[ "tc_1" ] aborted_steps

(* A tool that never runs because of the abort gets no on_tool_call_start. *)
let test_abort_skips_tool_call_start () =
  let started = ref [] in
  let integration =
    {
      Ai_core.Telemetry.no_integration with
      on_tool_call_start =
        Some
          (fun e ->
            started := e.tool_call_id :: !started;
            Lwt.return_unit);
    }
  in
  let telemetry = Ai_core.Telemetry.create ~enabled:true ~integrations:[ integration ] () in
  let (_ : Ai_core.Generate_text_result.step list option), (_ : string list), (_ : int) =
    run_abort_in_tool ~telemetry ~abort_in:"tc_1" ()
  in
  (check (list string)) "tool call starts" [ "tc_1" ] (List.rev !started)

(* Telemetry fires the signal while it reports the first tool's result. The
   tool returned before that, so its result counts, and the second tool
   never runs. *)
let test_abort_in_tool_call_finish_keeps_result () =
  let model, (_ : Mock.t) = make_abort_tool_model ~tool_call_ids:[ "tc_1"; "tc_2" ] () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let integration =
    {
      Ai_core.Telemetry.no_integration with
      on_tool_call_finish =
        Some
          (fun e ->
            if String.equal e.tool_call_id "tc_1" then abort ();
            Lwt.return_unit);
    }
  in
  let telemetry = Ai_core.Telemetry.create ~enabled:true ~integrations:[ integration ] () in
  let runs = ref 0 in
  let aborted_steps = ref None in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", counting_search_tool runs ]
        ~telemetry ~max_steps:3 ~abort_signal:signal
        ~on_abort:(fun ~steps -> aborted_steps := Some steps)
        ())
  in
  (check string) "outcome" "aborted" outcome;
  (check int) "tool runs" 1 !runs;
  check_aborted_step
    ~usage:{ input_tokens = 10; output_tokens = 5; total_tokens = Some 15 }
    ~tool_calls:[ "tc_1"; "tc_2" ] ~tool_results:[ "tc_1" ] !aborted_steps

(* The first integration's on_tool_call_start takes 0.3 s, and a cancel or
   an abort comes at 0.05 s. The call ends at once, the second integration
   hears nothing, and the tool never runs, whether the slow callback stops
   at the cancel or ignores it and returns later. *)
let test_telemetry_stops_after_cancel_or_abort () =
  let run ~slow ?abort_signal wrap =
    let second = ref [] in
    let first = { Ai_core.Telemetry.no_integration with on_tool_call_start = Some (fun _ -> slow ()) } in
    let recording =
      {
        Ai_core.Telemetry.no_integration with
        on_tool_call_start =
          Some
            (fun _ ->
              second := "start" :: !second;
              Lwt.return_unit);
        on_tool_call_finish =
          Some
            (fun _ ->
              second := "finish" :: !second;
              Lwt.return_unit);
      }
    in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~integrations:[ first; recording ] () in
    let model, (_ : Mock.t) = make_abort_tool_model () in
    let runs = ref 0 in
    let started = Unix.gettimeofday () in
    let outcome =
      generate_outcome (fun () ->
        wrap (fun () ->
          Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
            ~tools:[ "search", counting_search_tool runs ]
            ~telemetry ~max_steps:3 ?abort_signal ()))
    in
    let elapsed = Unix.gettimeofday () -. started in
    (* Let the slow callback run out. *)
    Lwt_main.run (Lwt_unix.sleep 0.3);
    outcome, elapsed, List.rev !second, !runs
  in
  let check_run name (outcome, elapsed, second, runs) expected =
    (check string) (name ^ ": outcome") expected outcome;
    (check bool) (Printf.sprintf "%s: ends at once (%.2f s)" name elapsed) true (elapsed < 0.2);
    (check (list string)) (name ^ ": second integration") [] second;
    (check int) (name ^ ": tool runs") 0 runs
  in
  let cancelable () = Lwt_unix.sleep 0.3 in
  let ignoring_cancel () = Lwt.no_cancel (Lwt_unix.sleep 0.3) in
  let cancel f = Lwt_unix.with_timeout 0.05 f in
  let abort_signal () = Ai_provider.Abort_signal.of_promise (Lwt_unix.sleep 0.05) in
  check_run "cancel" (run ~slow:cancelable cancel) "Lwt_unix.Timeout";
  check_run "cancel, callback ignores it" (run ~slow:ignoring_cancel cancel) "Lwt_unix.Timeout";
  check_run "abort" (run ~slow:cancelable ~abort_signal:(abort_signal ()) (fun f -> f ())) "aborted";
  check_run "abort, callback ignores the cancel"
    (run ~slow:ignoring_cancel ~abort_signal:(abort_signal ()) (fun f -> f ()))
    "aborted"

(* A callback that fails with its own [Lwt.Canceled] in a call that nobody
   cancelled or aborted is an ordinary integration error: it is printed, and
   the next integration still hears every event. *)
let test_telemetry_own_canceled_is_an_error () =
  let second = ref [] in
  let own_cancel _ = Lwt.fail Lwt.Canceled in
  let first =
    {
      Ai_core.Telemetry.no_integration with
      on_tool_call_start = Some own_cancel;
      on_tool_call_finish = Some own_cancel;
      on_step_finish = Some own_cancel;
      on_finish = Some own_cancel;
    }
  in
  let record name _ =
    second := name :: !second;
    Lwt.return_unit
  in
  let recording =
    {
      Ai_core.Telemetry.no_integration with
      on_tool_call_start = Some (record "tool start");
      on_tool_call_finish = Some (record "tool finish");
      on_step_finish = Some (record "step finish");
      on_finish = Some (record "finish");
    }
  in
  let telemetry = Ai_core.Telemetry.create ~enabled:true ~integrations:[ first; recording ] () in
  let model, (_ : Mock.t) = make_abort_tool_model () in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", counting_search_tool (ref 0) ]
        ~telemetry ~max_steps:2 ())
  in
  (check string) "outcome" "finished" outcome;
  (* The first step runs the tool. The second reaches [max_steps], so its
     tool call doesn't run. *)
  (check (list string))
    "second integration"
    [ "tool start"; "tool finish"; "step finish"; "step finish"; "finish" ]
    (List.rev !second)

(* An exception from on_abort is ignored, and the call fails with [Aborted]. *)
let test_on_abort_raises () =
  let model, (_ : Mock.t) = make_abort_tool_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", counting_search_tool ~abort (ref 0) ]
        ~max_steps:3 ~abort_signal:signal
        ~on_abort:(fun ~steps:_ -> failwith "on_abort failed")
        ())
  in
  (check string) "outcome" "aborted" outcome

(* A tool that runs a sub-agent under its own timeout, in a call with no
   signal. The timeout is the tool's error result, and the call goes on. *)
let test_tool_own_timeout_is_error_result () =
  let model, mock = make_abort_tool_model () in
  let tool =
    {
      search_tool with
      execute =
        Some
          (fun (_ : Yojson.Basic.t) _ ->
            Ai_provider.Abort_signal.with_timeout 0.01 (fun signal ->
              Ai_provider.Abort_signal.race (Some signal) (fun () ->
                let%lwt () = Lwt_unix.sleep 1.0 in
                Lwt.return (`String "late"))));
    }
  in
  let result =
    Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Search" ~tools:[ "search", tool ] ~max_steps:2 ())
  in
  (check int) "two model calls" 2 (model_calls mock);
  match result.steps with
  | { tool_results = [ { is_error = true; result = `String text; _ } ]; _ } :: _ ->
    (check string) "error result" "Abort_signal.Aborted(Abort_signal.Timeout(0.01s))" text
  | _ -> fail "expected a first step with one error result"

(* A tool that cancels its own work when the signal fires fails with
   [Canceled]. That counts as the abort: on_abort gets the step. *)
let test_tool_cancelling_itself_on_abort () =
  let model, (_ : Mock.t) = make_abort_tool_model () in
  let tool =
    {
      search_tool with
      execute =
        Some
          (fun (_ : Yojson.Basic.t) (options : Ai_core.Core_tool.execute_options) ->
            let work, (_ : Yojson.Basic.t Lwt.u) = Lwt.task () in
            match options.abort_signal with
            | Some signal -> Ai_provider.Abort_signal.with_on_abort signal (fun () -> Lwt.cancel work) (fun () -> work)
            | None -> work);
    }
  in
  let aborted_steps = ref None in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", tool ]
        ~max_steps:3
        ~abort_signal:(Ai_provider.Abort_signal.of_promise (Lwt_unix.sleep 0.05))
        ~on_abort:(fun ~steps -> aborted_steps := Some steps)
        ())
  in
  (check string) "outcome" "aborted" outcome;
  check_aborted_step
    ~usage:{ input_tokens = 10; output_tokens = 5; total_tokens = Some 15 }
    ~tool_calls:[ "tc_1" ] ~tool_results:[] !aborted_steps

(* The second of two approved pending tools fires the signal. The first
   one's result is kept in the step, and the model is never called. *)
let test_abort_in_pending_approval_keeps_result () =
  let pending tool_call_id : Ai_core.Generate_text_result.pending_tool_approval =
    { tool_call_id; tool_name = "search"; args = `Assoc []; approved = true }
  in
  let aborted_steps, ran, calls =
    run_abort_in_tool ~pending_tool_approvals:[ pending "tc_a"; pending "tc_b" ] ~abort_in:"tc_b" ()
  in
  check_aborted_step
    ~usage:{ input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }
    ~tool_calls:[ "tc_a"; "tc_b" ] ~tool_results:[ "tc_a" ] aborted_steps;
  (check (list string)) "tools that ran" [ "tc_a"; "tc_b" ] ran;
  (check int) "model never called" 0 calls

(* on_abort is only for the signal. A cancel fails the call without it, and
   an [Aborted] that a tool raises while the signal is pending is the tool's
   error result, so the call finishes. *)
let test_on_abort_only_for_signal () =
  let model, (_ : Mock.t) = make_abort_tool_model () in
  let signal, (_ : ?reason:exn -> unit -> unit) = Ai_provider.Abort_signal.create () in
  let reported = ref false in
  let generate execute =
    Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
      ~tools:[ "search", { search_tool with execute = Some execute } ]
      ~max_steps:3 ~abort_signal:signal
      ~on_abort:(fun ~steps:(_ : Ai_core.Generate_text_result.step list) -> reported := true)
      ()
  in
  let waiting, (_ : Yojson.Basic.t Lwt.u) = Lwt.task () in
  let call = generate (fun (_ : Yojson.Basic.t) _ -> waiting) in
  Lwt.cancel call;
  (check bool) "cancelled" true
    (match Lwt.state call with
    | Lwt.Fail Lwt.Canceled -> true
    | Lwt.Fail _ | Lwt.Return _ | Lwt.Sleep -> false);
  let outcome =
    generate_outcome (fun () ->
      generate (fun (_ : Yojson.Basic.t) _ -> Lwt.fail (Ai_provider.Abort_signal.Aborted { reason = None })))
  in
  (check string) "outcome" "finished" outcome;
  (check bool) "on_abort not called" false !reported

(* Names each message by its role. *)
let roles messages =
  List.map
    (fun (message : Ai_provider.Prompt.message) ->
      match message with
      | System _ -> "system"
      | User _ -> "user"
      | Assistant _ -> "assistant"
      | Tool _ -> "tool")
    messages

(* A [search] tool that records the options of each run in [seen], latest
   first. *)
let recording_search_tool seen =
  {
    search_tool with
    execute =
      Some
        (fun (_ : Yojson.Basic.t) (options : Ai_core.Core_tool.execute_options) ->
          seen := options :: !seen;
          Lwt.return (`String "results"));
  }

let has_signal signal (options : Ai_core.Core_tool.execute_options) =
  match options.abort_signal with
  | Some s -> s == signal
  | None -> false

(* Each run gets the signal, its call id and the messages of the step that
   produced the call, without the system prompt or that step's response. *)
let test_tool_execute_options () =
  let model, mock = make_abort_tool_model () in
  let signal, _abort = Ai_provider.Abort_signal.create () in
  let seen = ref [] in
  let (_ : Ai_core.Generate_text_result.t) =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~system:"Be brief" ~prompt:"Search"
         ~tools:[ "search", recording_search_tool seen ]
         ~max_steps:3 ~abort_signal:signal ())
  in
  let runs = List.rev !seen in
  (check (list string))
    "tool call ids" [ "tc_1"; "tc_1" ]
    (List.map (fun (options : Ai_core.Core_tool.execute_options) -> options.tool_call_id) runs);
  (check (list (list string)))
    "messages"
    [ [ "user" ]; [ "user"; "assistant"; "tool" ] ]
    (List.map (fun (options : Ai_core.Core_tool.execute_options) -> roles options.messages) runs);
  (check (list bool)) "signal" [ true; true ] (List.map (has_signal signal) runs);
  (check (list (list string)))
    "the model still gets the system prompt"
    [
      [ "system"; "user" ];
      [ "system"; "user"; "assistant"; "tool" ];
      [ "system"; "user"; "assistant"; "tool"; "assistant"; "tool" ];
    ]
    (List.map (fun (options : Ai_provider.Call_options.t) -> roles options.prompt) (Mock.generate_calls mock))

let pending_request_messages : Ai_provider.Prompt.message list =
  [
    User { content = [ Text { text = "Search"; provider_options = Ai_provider.Provider_options.empty } ] };
    Assistant
      {
        content =
          [
            Tool_call
              { id = "tc_0"; name = "search"; args = `Assoc []; provider_options = Ai_provider.Provider_options.empty };
          ];
      };
  ]

(* An approved pending tool runs before the first step and gets the request's
   messages. *)
let test_pending_tool_execute_options () =
  let model, (_ : Mock.t) = make_abort_tool_model () in
  let signal, _abort = Ai_provider.Abort_signal.create () in
  let seen = ref [] in
  let pending : Ai_core.Generate_text_result.pending_tool_approval =
    { tool_call_id = "tc_0"; tool_name = "search"; args = `Assoc []; approved = true }
  in
  let (_ : Ai_core.Generate_text_result.t) =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~system:"Be brief" ~messages:pending_request_messages
         ~tools:[ "search", recording_search_tool seen ]
         ~pending_tool_approvals:[ pending ] ~max_steps:2 ~abort_signal:signal ())
  in
  match !seen with
  | [ options ] ->
    (check string) "tool call id" "tc_0" options.tool_call_id;
    (check (list string)) "messages" [ "user"; "assistant" ] (roles options.messages);
    (check bool) "signal" true (has_signal signal options)
  | runs -> Alcotest.failf "expected one run, got %d" (List.length runs)

(* A tool that waits on the signal ends when it fires, so the call fails at
   the abort and not when a tool that ignores the signal would end. *)
let test_abort_reaches_tool () =
  let model, (_ : Mock.t) = make_abort_tool_model () in
  let tool =
    {
      search_tool with
      execute =
        Some
          (fun (_ : Yojson.Basic.t) (options : Ai_core.Core_tool.execute_options) ->
            let%lwt () =
              match options.abort_signal with
              | Some signal -> Ai_provider.Abort_signal.wait signal
              | None -> Lwt_unix.sleep 1.0
            in
            Lwt.return (`String "stopped"));
    }
  in
  let started = Unix.gettimeofday () in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", tool ]
        ~max_steps:3
        ~abort_signal:(Ai_provider.Abort_signal.of_promise (Lwt_unix.sleep 0.3))
        ())
  in
  let elapsed = Unix.gettimeofday () -. started in
  (check string) "outcome" "aborted" outcome;
  (check bool) (Printf.sprintf "fails at the abort (%.2f s)" elapsed) true (elapsed < 0.6)

(* A [search] tool that counts its runs and returns after [run]. *)
let waiting_search_tool runs run =
  {
    search_tool with
    execute =
      Some
        (fun (_ : Yojson.Basic.t) _ ->
          incr runs;
          let%lwt () = run () in
          Lwt.return (`String "results"));
  }

(* Runs [generate_text] under [Lwt_unix.with_timeout timeout_s], checks that
   it fails with [Timeout] within [deadline_s], then waits [settle_s] for
   anything the cancel left running. *)
let check_cancelled_by_timeout ~timeout_s ~deadline_s ~settle_s run =
  let started = Unix.gettimeofday () in
  let outcome =
    Lwt_main.run
      (Lwt.catch
         (fun () ->
           let%lwt (_ : Ai_core.Generate_text_result.t) = Lwt_unix.with_timeout timeout_s run in
           Lwt.return "finished")
         (function
           | Lwt_unix.Timeout -> Lwt.return "timeout"
           | exn -> Lwt.return (Printexc.to_string exn)))
  in
  let elapsed = Unix.gettimeofday () -. started in
  (check string) "outcome" "timeout" outcome;
  (check bool) (Printf.sprintf "fails at the timeout (%.2f s)" elapsed) true (elapsed < deadline_s);
  Lwt_main.run (Lwt_unix.sleep settle_s)

(* The consumer repro: a cancel during a tool used to become the tool's error
   result, and a second model request nobody read went out. The tool's sleep
   is cancelled, so it never finishes. *)
let test_cancel_stops_tool_and_loop () =
  let model, mock = make_abort_tool_model () in
  let finished = ref false in
  let tool =
    waiting_search_tool (ref 0) (fun () ->
      let%lwt () = Lwt_unix.sleep 1.0 in
      finished := true;
      Lwt.return_unit)
  in
  check_cancelled_by_timeout ~timeout_s:0.3 ~deadline_s:0.5 ~settle_s:1.2 (fun () ->
    Ai_core.Generate_text.generate_text ~model ~prompt:"Search" ~tools:[ "search", tool ] ~max_steps:3 ());
  (check int) "one model call" 1 (model_calls mock);
  (check bool) "tool cancelled" false !finished

(* A tool that ignores the signal no longer holds the call: it fails at the
   abort, and the tool's sleep is cancelled. *)
let test_abort_with_tool_ignoring_signal () =
  let model, mock = make_abort_tool_model () in
  let finished = ref false in
  let tool =
    waiting_search_tool (ref 0) (fun () ->
      let%lwt () = Lwt_unix.sleep 1.0 in
      finished := true;
      Lwt.return_unit)
  in
  let started = Unix.gettimeofday () in
  let outcome =
    generate_outcome (fun () ->
      Ai_provider.Abort_signal.with_timeout 0.3 (fun abort_signal ->
        Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
          ~tools:[ "search", tool ]
          ~max_steps:3 ~abort_signal ()))
  in
  let elapsed = Unix.gettimeofday () -. started in
  Lwt_main.run (Lwt_unix.sleep 1.0);
  (check string) "outcome" "aborted" outcome;
  (check bool) (Printf.sprintf "fails at the abort (%.2f s)" elapsed) true (elapsed < 0.5);
  (check int) "one model call" 1 (model_calls mock);
  (check bool) "tool cancelled" false !finished

(* A tool that ignores [Lwt.cancel] keeps running, but the call fails at the
   cancel and starts neither the next tool nor the next model request. *)
let test_cancel_with_uncancelable_tool () =
  let model, mock = make_abort_tool_model ~tool_call_ids:[ "tc_1"; "tc_2" ] () in
  let runs = ref 0 in
  let tool = waiting_search_tool runs (fun () -> Lwt.no_cancel (Lwt_unix.sleep 0.4)) in
  check_cancelled_by_timeout ~timeout_s:0.2 ~deadline_s:0.35 ~settle_s:0.5 (fun () ->
    Ai_core.Generate_text.generate_text ~model ~prompt:"Search" ~tools:[ "search", tool ] ~max_steps:3 ());
  (check int) "one tool run" 1 !runs;
  (check int) "one model call" 1 (model_calls mock)

(* The call is cancelled, then its signal fires while a tool that ignores
   both is still running. A cancelled call is not aborted: on_abort and
   on_step_finish are not called. *)
let test_cancel_then_abort_skips_on_abort () =
  let model, (_ : Mock.t) = make_abort_tool_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let aborted = ref false in
  let step_finished = ref false in
  let tool = waiting_search_tool (ref 0) (fun () -> Lwt.no_cancel (Lwt_unix.sleep 0.3)) in
  Lwt.dont_wait
    (fun () ->
      let%lwt () = Lwt_unix.sleep 0.2 in
      abort ();
      Lwt.return_unit)
    (fun (_ : exn) -> ());
  check_cancelled_by_timeout ~timeout_s:0.1 ~deadline_s:0.2 ~settle_s:0.4 (fun () ->
    Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
      ~tools:[ "search", tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_step_finish:(fun (_ : Ai_core.Generate_text_result.step) -> step_finished := true)
      ~on_abort:(fun ~steps:_ -> aborted := true)
      ());
  (check bool) "on_abort not called" false !aborted;
  (check bool) "on_step_finish not called" false !step_finished

(* A model call that ignores [Lwt.cancel] returns its tool call after the
   cancel, and the tool never runs. *)
let test_cancel_with_uncancelable_model () =
  let model, mock =
    Mock.create
      ~generate:
        (Respond
           (fun (_ : Ai_provider.Call_options.t) ->
             let%lwt () = Lwt.no_cancel (Lwt_unix.sleep 0.4) in
             Lwt.return (search_call_result ())))
      ()
  in
  let runs = ref 0 in
  let tool = waiting_search_tool runs Lwt.return in
  check_cancelled_by_timeout ~timeout_s:0.2 ~deadline_s:0.35 ~settle_s:0.5 (fun () ->
    Ai_core.Generate_text.generate_text ~model ~prompt:"Search" ~tools:[ "search", tool ] ~max_steps:3 ());
  (check int) "tool never runs" 0 !runs;
  (check int) "one model call" 1 (model_calls mock)

(* Answers the first call with a tool call, then never answers and ignores
   both the abort signal and [Lwt.cancel]. *)
let make_model_ignoring_signal () =
  let answered = ref false in
  Mock.create
    ~generate:
      (Respond
         (fun (_ : Ai_provider.Call_options.t) ->
           match !answered with
           | false ->
             answered := true;
             Lwt.return (search_call_result ())
           | true ->
             let never, (_ : Ai_provider.Generate_result.t Lwt.u) = Lwt.wait () in
             never))
    ()

(* The call races the model against the signal, so it fails at the abort and
   reports the first step even though the second model call never returns. *)
let test_abort_with_model_ignoring_signal () =
  let model, mock = make_model_ignoring_signal () in
  let aborted_steps = ref None in
  let started = Unix.gettimeofday () in
  let outcome =
    generate_outcome (fun () ->
      Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
        ~tools:[ "search", waiting_search_tool (ref 0) Lwt.return ]
        ~max_steps:3
        ~abort_signal:(Ai_provider.Abort_signal.of_promise (Lwt_unix.sleep 0.1))
        ~on_abort:(fun ~steps -> aborted_steps := Some steps)
        ())
  in
  let elapsed = Unix.gettimeofday () -. started in
  (check string) "outcome" "aborted" outcome;
  (check bool) (Printf.sprintf "fails at the abort (%.2f s)" elapsed) true (elapsed < 0.3);
  (check int) "two model calls" 2 (model_calls mock);
  match !aborted_steps with
  | Some [ step ] -> (check int) "step usage" 10 step.usage.input_tokens
  | Some steps -> Alcotest.failf "on_abort got %d steps, expected 1" (List.length steps)
  | None -> fail "on_abort was not called"

(* [Lwt.cancel] still ends a call that has a signal while the model ignores
   both, and the cancel does not reach the caller's signal. *)
let test_cancel_with_signal_and_model_ignoring_it () =
  let model, (_ : Mock.t) = make_model_ignoring_signal () in
  let signal = Ai_provider.Abort_signal.of_promise (fst (Lwt.task ())) in
  check_cancelled_by_timeout ~timeout_s:0.2 ~deadline_s:0.35 ~settle_s:0. (fun () ->
    Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
      ~tools:[ "search", waiting_search_tool (ref 0) Lwt.return ]
      ~max_steps:3 ~abort_signal:signal ());
  (check bool) "signal still pending" false (Ai_provider.Abort_signal.is_aborted signal)

(* A model whose own abort hook, attached after a pause, fails the request
   with [exn] before the call's race sees the signal. *)
let make_model_failing_on_abort exn =
  Mock.create
    ~generate:
      (Respond
         (fun (options : Ai_provider.Call_options.t) ->
           let response, resolver = Lwt.wait () in
           let%lwt () = Lwt.pause () in
           match options.abort_signal with
           | None -> response
           | Some signal ->
             Ai_provider.Abort_signal.with_on_abort signal (fun () -> Lwt.wakeup_exn resolver exn) (fun () -> response)))
    ()

(* Once the call's signal has fired, whatever the model fails with is the
   abort: the call fails with [Aborted] and [on_abort] is called. *)
let test_abort_with_model_failing_otherwise () =
  List.iter
    (fun exn ->
      let model, (_ : Mock.t) = make_model_failing_on_abort exn in
      let aborted_steps = ref None in
      let outcome =
        generate_outcome (fun () ->
          Ai_provider.Abort_signal.with_timeout 0.05 (fun abort_signal ->
            Ai_core.Generate_text.generate_text ~model ~prompt:"Hello" ~abort_signal
              ~on_abort:(fun ~steps -> aborted_steps := Some (List.length steps))
              ()))
      in
      let name = Printexc.to_string exn in
      (check string) (name ^ ": outcome") "aborted" outcome;
      (check (option int)) (name ^ ": on_abort") (Some 0) !aborted_steps)
    [
      Failure "socket closed";
      Lwt.Canceled;
      Ai_provider.Provider_error.Provider_error
        { provider = "p"; kind = Network_error { message = "reset" }; is_retryable = false; retry_after_s = None };
    ]

(* on_abort runs, with the step whose tool fired the signal, before the
   returned promise fails. *)
let test_on_abort_before_failure () =
  let model, (_ : Mock.t) = make_abort_tool_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let events = ref [] in
  let record event = events := event :: !events in
  let tool =
    {
      search_tool with
      execute =
        Some
          (fun (_ : Yojson.Basic.t) _ ->
            let%lwt () = Lwt.pause () in
            abort ();
            Lwt.return (`String "results"));
    }
  in
  let call_ref = ref None in
  Lwt_main.run
    (let call =
       Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
         ~tools:[ "search", tool ]
         ~max_steps:3 ~abort_signal:signal
         ~on_abort:(fun ~steps ->
           let pending = Option.fold ~none:false ~some:Lwt.is_sleeping !call_ref in
           record (Printf.sprintf "on_abort with %d steps, pending %b" (List.length steps) pending))
         ()
     in
     call_ref := Some call;
     (check bool) "pending before the abort" true (Lwt.is_sleeping call);
     Lwt.on_failure call (function
       | Ai_provider.Abort_signal.Aborted _ -> record "failed with Aborted"
       | exn -> record (Printexc.to_string exn));
     Lwt.catch
       (fun () ->
         let%lwt (_ : Ai_core.Generate_text_result.t) = call in
         Lwt.return_unit)
       (fun (_ : exn) -> Lwt.return_unit));
  (check (list string)) "order" [ "on_abort with 1 steps, pending true"; "failed with Aborted" ] (List.rev !events)

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
          test_case "execute_options" `Quick test_tool_execute_options;
          test_case "pending_execute_options" `Quick test_pending_tool_execute_options;
        ] );
      ( "approval",
        [
          test_case "approval_stops_loop" `Quick test_approval_stops_loop;
          test_case "no_approval_executes_normally" `Quick test_no_approval_executes_normally;
          test_case "dynamic_approval_conditional" `Quick test_dynamic_approval_conditional;
          test_case "approved_tool_executes" `Quick test_approved_tool_executes;
          test_case "mixed_tools_safe_executes" `Quick test_mixed_tools_safe_executes;
        ] );
      ( "stop_when",
        [
          test_case "step_count" `Quick test_stop_when_step_count;
          test_case "has_tool_call" `Quick test_stop_when_has_tool_call;
          test_case "max_steps_still_limits" `Quick test_stop_when_max_steps_still_limits;
          test_case "or_semantics" `Quick test_stop_when_or_semantics;
          test_case "empty_conditions" `Quick test_stop_when_empty_conditions;
          test_case "custom_predicate" `Quick test_stop_when_custom_predicate;
          test_case "not_set_continues" `Quick test_stop_when_not_set;
        ] );
      "errors", [ test_case "prompt_and_messages" `Quick test_prompt_and_messages_conflict ];
      ( "abort",
        [
          test_case "between_steps" `Quick test_abort_between_steps;
          test_case "between_tools" `Quick test_abort_between_tools;
          test_case "before_pending_approval" `Quick test_abort_before_pending_approval;
          test_case "in_tool_batch_keeps_step" `Quick test_abort_in_tool_batch_keeps_step;
          test_case "in_second_tool_keeps_first_result" `Quick test_abort_in_second_tool_keeps_first_result;
          test_case "in_tool_at_depth_1" `Quick test_abort_in_tool_at_depth_1;
          test_case "in_last_tool_with_stop_when" `Quick test_abort_in_last_tool_with_stop_when;
          test_case "skips_tool_call_start" `Quick test_abort_skips_tool_call_start;
          test_case "in_tool_call_finish_keeps_result" `Quick test_abort_in_tool_call_finish_keeps_result;
          test_case "telemetry_stops_after_cancel_or_abort" `Quick test_telemetry_stops_after_cancel_or_abort;
          test_case "telemetry_own_canceled_is_an_error" `Quick test_telemetry_own_canceled_is_an_error;
          test_case "on_abort_raises" `Quick test_on_abort_raises;
          test_case "tool_own_timeout_is_error_result" `Quick test_tool_own_timeout_is_error_result;
          test_case "tool_cancelling_itself" `Quick test_tool_cancelling_itself_on_abort;
          test_case "in_pending_approval_keeps_result" `Quick test_abort_in_pending_approval_keeps_result;
          test_case "on_abort_only_for_signal" `Quick test_on_abort_only_for_signal;
          test_case "on_abort_before_failure" `Quick test_on_abort_before_failure;
          test_case "reaches_tool" `Quick test_abort_reaches_tool;
          test_case "cancel_stops_tool_and_loop" `Quick test_cancel_stops_tool_and_loop;
          test_case "tool_ignoring_signal" `Quick test_abort_with_tool_ignoring_signal;
          test_case "cancel_with_uncancelable_tool" `Quick test_cancel_with_uncancelable_tool;
          test_case "cancel_then_abort" `Quick test_cancel_then_abort_skips_on_abort;
          test_case "cancel_with_uncancelable_model" `Quick test_cancel_with_uncancelable_model;
          test_case "model_ignoring_signal" `Quick test_abort_with_model_ignoring_signal;
          test_case "cancel_with_signal_and_model_ignoring_it" `Quick test_cancel_with_signal_and_model_ignoring_it;
          test_case "model_failing_otherwise" `Quick test_abort_with_model_failing_otherwise;
        ] );
      ( "retry",
        [
          test_case "retries_on_retryable_error" `Quick test_generate_retries_on_retryable_error;
          test_case "no_retry_on_non_retryable" `Quick test_generate_no_retry_on_non_retryable;
        ] );
      ( "output",
        [
          test_case "object_output" `Quick test_generate_with_object_output;
          test_case "enum_output" `Quick test_generate_with_enum_output;
          test_case "array_output" `Quick test_generate_with_array_output;
          test_case "invalid_output" `Quick test_generate_with_invalid_output;
          test_case "no_output" `Quick test_generate_without_output;
        ] );
      ( "telemetry",
        [
          test_case "spans" `Quick test_telemetry_spans;
          test_case "tool_spans" `Quick test_telemetry_tool_spans;
          test_case "root_attributes" `Quick test_telemetry_root_attributes;
          test_case "disabled_no_spans" `Quick test_telemetry_disabled_no_spans;
          test_case "integration_callbacks" `Quick test_telemetry_integration_callbacks;
          test_case "no_outputs" `Quick test_telemetry_no_outputs;
          test_case "no_inputs" `Quick test_telemetry_no_inputs;
          test_case "step_response_attrs" `Quick test_telemetry_step_response_attrs;
          test_case "attribute_values" `Quick test_telemetry_attribute_values;
        ] );
    ]
