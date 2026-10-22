open Melange_json.Primitives
open Alcotest

type query_args = { query : string } [@@json.allow_extra_fields] [@@deriving of_json]

module Mock = Ai_mock.Language_model

(* Token counts whose total is their sum. *)
let tokens input_tokens output_tokens : Ai_provider.Usage.t =
  { input_tokens; output_tokens; total_tokens = Some (input_tokens + output_tokens) }

let stream_start = Ai_provider.Stream_part.Stream_start { warnings = [] }

let finish_part ?(finish_reason = Ai_provider.Finish_reason.Stop) usage =
  Ai_provider.Stream_part.Finish { finish_reason; usage; provider_metadata = None }

(* The parts that stream one whole tool call. *)
let tool_call_parts ?(tool_name = "search") ?(args = {|{"query":"test"}|}) tool_call_id =
  [
    Ai_provider.Stream_part.Tool_call_delta
      { tool_call_type = "function"; tool_call_id; tool_name; args_text_delta = args };
    Tool_call_finish { tool_call_id };
  ]

let model_calls mock = List.length (Mock.stream_calls mock)

(* Mock streaming model -- emits text deltas *)
let make_text_stream_model response_text =
  (* Split text into characters for realistic streaming *)
  let deltas =
    List.map
      (fun c -> Ai_provider.Stream_part.Text { text = String.make 1 c })
      (List.of_seq (String.to_seq response_text))
  in
  let parts = (stream_start :: deltas) @ [ finish_part (tokens 10 5) ] in
  let raw_response : Ai_provider.Generate_result.response_info =
    { id = Some "stream-1"; model = Some "actual-stream-model"; headers = []; body = `Null }
  in
  fst
    (Mock.create ~provider:"mock" ~model_id:"mock-stream"
       ~stream:
         (Respond
            (fun (_ : Ai_provider.Call_options.t) ->
              Lwt.return { (Mock.stream_result parts) with raw_response = Some raw_response }))
       ())

(* Mock model that streams a tool call then text on second call *)
let make_tool_stream_model () =
  fst
    (Mock.create
       ~stream:
         (Sequence
            [
              (stream_start :: Text { text = "Searching..." } :: tool_call_parts "tc_1")
              @ [ finish_part ~finish_reason:Tool_calls (tokens 10 8) ];
              [ stream_start; Text { text = "Found it!" }; finish_part (tokens 20 5) ];
            ])
       ())

let search_tool : Ai_core.Core_tool.t =
  {
    description = Some "Search";
    parameters = `Assoc [ "type", `String "object" ];
    execute =
      Some
        (fun args _ ->
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
  let delta args_text_delta =
    Ai_provider.Stream_part.Tool_call_delta
      { tool_call_type = "function"; tool_call_id = "tc_json_1"; tool_name = "json"; args_text_delta }
  in
  let parts =
    (stream_start :: List.map delta chunks)
    @ [ Tool_call_finish { tool_call_id = "tc_json_1" }; finish_part ~finish_reason:Tool_calls (tokens 10 8) ]
  in
  fst (Mock.create ~stream:(Return parts) ())

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
  let parts =
    stream_start
    :: Text { text = "Let me check." }
    :: tool_call_parts ~tool_name:"dangerous_action" ~args:{|{"target":"prod"}|} "tc_1"
    @ [ finish_part ~finish_reason:Tool_calls (tokens 10 8) ]
  in
  fst (Mock.create ~stream:(Return parts) ())

let approval_tool : Ai_core.Core_tool.t =
  Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
    ~parameters:(`Assoc [ "type", `String "object" ])
    ~execute:(fun _ _ -> Lwt.return (`String "executed"))
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

let test_approved_tool_executes_stream () =
  (* Model that just returns text — the tool was already executed in the initial step *)
  let model = make_text_stream_model "Done!" in
  let tool =
    Ai_core.Core_tool.create_with_approval ~description:"Dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ _ -> Lwt.return (`String "executed"))
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
      ~execute:(fun _ _ -> Lwt.return (`String "should not execute"))
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
  let parts =
    (stream_start :: Text { text = "Doing both." } :: tool_call_parts ~tool_name:"safe_action" "tc_safe")
    @ tool_call_parts ~tool_name:"dangerous_action" ~args:{|{"target":"prod"}|} "tc_danger"
    @ [ finish_part ~finish_reason:Tool_calls (tokens 10 15) ]
  in
  fst (Mock.create ~stream:(Return parts) ())

let test_mixed_tools_safe_executes_stream () =
  let model = make_mixed_stream_model () in
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
  let calls = ref 0 in
  let respond (_ : Ai_provider.Call_options.t) =
    incr calls;
    let tool_call =
      tool_call_parts ~args:(Printf.sprintf {|{"query":"step%d"}|} !calls) (Printf.sprintf "tc_%d" !calls)
    in
    Lwt.return
      (Mock.stream_result
         ((stream_start :: Text { text = Printf.sprintf "Step %d." !calls } :: tool_call)
         @ [ finish_part ~finish_reason:Tool_calls (tokens 10 10) ]))
  in
  fst (Mock.create ~stream:(Respond respond) ())

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
  let step tool_name tool_call_id =
    (stream_start :: tool_call_parts ~tool_name tool_call_id) @ [ finish_part ~finish_reason:Tool_calls (tokens 10 5) ]
  in
  let model, (_ : Mock.t) = Mock.create ~stream:(Sequence [ step "search" "tc_1"; step "done_tool" "tc_2" ]) () in
  let done_tool =
    Ai_core.Core_tool.create ~description:"Done"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ _ -> Lwt.return (`String "done"))
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
  let respond (_ : Ai_provider.Call_options.t) =
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
    else Lwt.return (Mock.stream_result [ Text { text = "streamed" }; finish_part (tokens 5 3) ])
  in
  call_count, fst (Mock.create ~stream:(Respond respond) ())

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
  let provider_metadata =
    Ai_provider.Provider_options.of_provider_metadata
      (`Assoc [ "anthropic", `Assoc [ "cache_creation_input_tokens", `Int 20; "cache_read_input_tokens", `Int 80 ] ])
  in
  fst
    (Mock.create
       ~stream:
         (Return
            [
              stream_start;
              Text { text = "hi" };
              Finish { finish_reason = Stop; usage = tokens 10 5; provider_metadata = Some provider_metadata };
            ])
       ())

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
   [usage] is the first call's usage. *)
let make_abort_stream_model ?(tool_call_ids = [ "tc_1" ]) ?(usage = tokens 10 8) ?(pause = false) () =
  let first_call = ref true in
  let respond options =
    match !first_call with
    | true ->
      first_call := false;
      let%lwt () =
        match pause with
        | true -> Lwt.pause ()
        | false -> Lwt.return_unit
      in
      Lwt.return
        (Mock.stream_result
           ((stream_start :: List.concat_map (fun id -> tool_call_parts id) tool_call_ids)
           @ [ finish_part ~finish_reason:Tool_calls usage ]))
    | false -> Mock.hanging_stream [ stream_start; Text { text = "Found" } ] options
  in
  Mock.create ~stream:(Respond respond) ()

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
  | Lwt.Fail (Ai_provider.Abort_signal.Aborted _) -> true
  | Lwt.Fail _ | Lwt.Return _ | Lwt.Sleep -> false

let check_result_aborted (result : Ai_core.Stream_text_result.t) =
  (check bool) "usage failed with Aborted" true (failed_with_aborted result.usage);
  (check bool) "finish_reason failed with Aborted" true (failed_with_aborted result.finish_reason);
  (check bool) "steps failed with Aborted" true (failed_with_aborted result.steps);
  (check bool) "output failed with Aborted" true (failed_with_aborted result.output);
  (check bool) "provider_metadata failed with Aborted" true (failed_with_aborted result.provider_metadata)

(* Reads [stream] up to and including the first part that satisfies [f]. *)
let rec read_until f stream ~acc =
  match%lwt Lwt_stream.get stream with
  | None -> Lwt.return (List.rev acc)
  | Some part when f part -> Lwt.return (List.rev (part :: acc))
  | Some part -> read_until f stream ~acc:(part :: acc)

let test_abort_mid_stream () =
  let model, mock = make_abort_stream_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
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
  abort ();
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
  (check int) "model calls" 2 (model_calls mock);
  (check (list bool))
    "every call got the signal" [ true; true ]
    (List.map
       (fun (options : Ai_provider.Call_options.t) -> Option.is_some options.abort_signal)
       (Mock.stream_calls mock));
  Lwt.return_unit

(* As upstream, [Start] comes before the [Abort] part even when the signal
   fired before the call. *)
let test_abort_before_start () =
  let model, mock = make_abort_stream_model () in
  let aborted_with = ref None in
  let chunks = ref [] in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~abort_signal:(Ai_provider.Abort_signal.of_promise Lwt.return_unit)
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
  (check int) "model never called" 0 (model_calls mock);
  Lwt.return_unit

(* The signal's reason reaches the [Abort] part, the UI [abort] chunk and the
   [Aborted] exception. *)
let test_abort_reason () =
  let model, (_ : Mock.t) = make_abort_stream_model () in
  let stream_aborted () =
    let signal, abort = Ai_provider.Abort_signal.create () in
    abort ~reason:Exit ();
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search" ~abort_signal:signal ()
  in
  let result = stream_aborted () in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  (check (list string)) "parts" [ "start"; "abort:Stdlib.Exit" ] (List.map part_name parts);
  let failed_with_reason promise =
    match Lwt.state promise with
    | Lwt.Fail (Ai_provider.Abort_signal.Aborted { reason = Some Exit }) -> true
    | Lwt.Fail _ | Lwt.Return _ | Lwt.Sleep -> false
  in
  (check bool) "usage failed with the reason" true (failed_with_reason result.usage);
  (check bool) "output failed with the reason" true (failed_with_reason result.output);
  (check bool) "provider_metadata failed with the reason" true (failed_with_reason result.provider_metadata);
  let%lwt sse = Lwt_stream.to_list (Ai_core.Stream_text_result.to_ui_message_sse_stream (stream_aborted ())) in
  (check bool) "UI abort chunk carries the reason" true
    (List.exists (fun event -> String.equal (String.trim event) {|data: {"type":"abort","reason":"Stdlib.Exit"}|}) sse);
  Lwt.return_unit

(* A long-lived signal, such as one for server shutdown, may fire after the
   request has finished. That must not reach the finished request. *)
let test_abort_after_finish () =
  let model = make_text_stream_model "Hello" in
  let abort_signal, abort = Ai_provider.Abort_signal.create () in
  let aborted = ref false in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hi" ~abort_signal ~on_abort:(fun ~steps:_ -> aborted := true) ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt (_ : Ai_provider.Finish_reason.t) = result.finish_reason in
  abort ();
  let%lwt () = Lwt.pause () in
  (check (option string)) "last part" (Some "finish") (List.nth_opt (List.rev_map part_name parts) 0);
  (check bool) "on_abort not called" false !aborted;
  (match Lwt.state result.finish_reason with
  | Return reason -> (check string) "finish reason" "stop" (Ai_provider.Finish_reason.to_string reason)
  | Fail exn -> failf "finish_reason failed: %s" (Printexc.to_string exn)
  | Sleep -> fail "finish_reason pending");
  Lwt.return_unit

(* Runs a search that fires the abort signal from [on_step_finish] or from the
   tool. Returns the parts, the number of steps on_abort got, the model call
   count and the tool run count. *)
let run_abort_in_first_step ~in_tool =
  let model, mock = make_abort_stream_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let tool_runs = ref 0 in
  let aborted_steps = ref None in
  let tool =
    {
      search_tool with
      execute =
        Some
          (fun (_ : Yojson.Basic.t) _ ->
            incr tool_runs;
            if in_tool then abort ();
            Lwt.return (`String "results"));
    }
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_step_finish:(fun (_ : Ai_core.Generate_text_result.step) -> if not in_tool then abort ())
      ~on_abort:(fun ~steps -> aborted_steps := Some (List.length steps))
      ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  check_result_aborted result;
  Lwt.return (List.map part_name parts, !aborted_steps, model_calls mock, !tool_runs)

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

(* The step's response came back before the tool ran, so on_abort gets the
   step. The tool's result comes after the abort, so the stream drops it. *)
let test_abort_during_tool () =
  let%lwt parts, aborted_steps, calls, tool_runs = run_abort_in_first_step ~in_tool:true in
  (check (list string)) "parts" [ "start"; "start-step"; "tool-call-delta"; "tool-call"; "abort" ] parts;
  (check (option int)) "on_abort gets the step" (Some 1) aborted_steps;
  (check int) "one model call" 1 calls;
  (check int) "one tool run" 1 tool_runs;
  Lwt.return_unit

(* The UI stream ends with the abort chunk and has no finish chunk. *)
let test_abort_ui_stream () =
  let model, (_ : Mock.t) = make_abort_stream_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", search_tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_chunk:(function
        | Text_delta _ -> abort ()
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

(* Runs [f] with [Lwt.async_exception_hook] collecting what reaches it,
   newest first, instead of exiting the process. *)
let with_async_exceptions f =
  let seen = ref [] in
  let previous = !Lwt.async_exception_hook in
  (Lwt.async_exception_hook := fun exn -> seen := exn :: !seen);
  Lwt.finalize
    (fun () -> f seen)
    (fun () ->
      Lwt.async_exception_hook := previous;
      Lwt.return_unit)

(* [Finish] is always the last part. An exception from [on_chunk] on it is
   ignored: it reaches neither the stream nor [Lwt.async_exception_hook], and
   the call still finishes. *)
let test_on_chunk_raises_on_finish () =
  with_async_exceptions @@ fun seen ->
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
    (Some [ "start"; "start-step"; "text-start"; "text-delta"; "text-delta"; "text-end"; "finish-step"; "finish" ])
    (Option.map (List.map part_name) parts);
  (check (option (list string))) "text_stream closes" (Some [ "H"; "i" ]) texts;
  (check bool) "partial_output_stream closes" true (Option.is_some partial);
  (check (list string)) "exception hook" [] (List.map Printexc.to_string !seen);
  let%lwt outcome = result.outcome in
  (check bool) "finished" true
    (match outcome with
    | Finished _ -> true
    | Aborted _ | Failed _ -> false);
  Lwt.return_unit

(* An abort from [on_chunk] on the [Finish] part comes after the call ended,
   so it changes nothing. *)
let test_abort_from_on_chunk_on_finish () =
  let signal, abort = Ai_provider.Abort_signal.create () in
  let aborted = ref false in
  let result =
    Ai_core.Stream_text.stream_text ~model:(make_text_stream_model "Hi") ~prompt:"Hello" ~abort_signal:signal
      ~on_chunk:(function
        | Finish _ -> abort ()
        | _ -> ())
      ~on_abort:(fun ~steps:_ -> aborted := true)
      ()
  in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  (check (option string))
    "last part" (Some "finish")
    (Option.bind parts (fun parts -> List.nth_opt (List.rev_map part_name parts) 0));
  (check bool) "on_abort not called" false !aborted;
  let%lwt outcome = result.outcome in
  (check bool) "finished" true
    (match outcome with
    | Finished _ -> true
    | Aborted _ | Failed _ -> false);
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

(* A [search] tool that counts its runs and calls [abort], when given. *)
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

let check_ends_with_abort parts =
  (check (option string))
    "last part" (Some "abort")
    (List.fold_left (fun (_ : string option) part -> Some (part_name part)) None parts)

(* The first of two tool calls fires the signal, so the second never runs. *)
let test_abort_between_tools () =
  let model, mock = make_abort_stream_model ~tool_call_ids:[ "tc_1"; "tc_2" ] () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let runs = ref 0 in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", counting_search_tool ~abort runs ]
      ~max_steps:3 ~abort_signal:signal ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  (check int) "one tool run" 1 !runs;
  (check int) "one model call" 1 (model_calls mock);
  check_ends_with_abort parts;
  check_result_aborted result;
  Lwt.return_unit

(* The first of two approved pending tools fires the signal, so the second
   never runs and the model is never called. *)
let test_abort_between_pending_approvals () =
  let model, mock = make_abort_stream_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let runs = ref 0 in
  let pending tool_call_id : Ai_core.Generate_text_result.pending_tool_approval =
    { tool_call_id; tool_name = "search"; args = `Assoc []; approved = true }
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", counting_search_tool ~abort runs ]
      ~pending_tool_approvals:[ pending "tc_a"; pending "tc_b" ]
      ~max_steps:3 ~abort_signal:signal ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  (check int) "one tool run" 1 !runs;
  (check int) "model never called" 0 (model_calls mock);
  check_ends_with_abort parts;
  check_result_aborted result;
  Lwt.return_unit

(* Checks that on_abort got one step with the model's usage, both tool calls
   and the results of [tool_results]. *)
let check_aborted_step ~tool_results (steps : Ai_core.Generate_text_result.step list option) =
  match steps with
  | Some [ step ] ->
    (check int) "input tokens" 10 step.usage.input_tokens;
    (check int) "output tokens" 5 step.usage.output_tokens;
    (check (option int)) "total tokens" (Some 15) step.usage.total_tokens;
    (check (list string))
      "tool calls" [ "tc_1"; "tc_2" ]
      (List.map (fun (tc : Ai_core.Generate_text_result.tool_call) -> tc.tool_call_id) step.tool_calls);
    (check (list string))
      "tool results" tool_results
      (List.map (fun (tr : Ai_core.Generate_text_result.tool_result) -> tr.tool_call_id) step.tool_results)
  | Some steps -> failf "expected one step, got %d" (List.length steps)
  | None -> fail "on_abort was not called"

(* The model asks for two tools in one step, and the tool of [abort_in] fires
   the signal and returns. With [~pause:true], the model and each tool pause
   first, so the abort comes from inside an Lwt callback. Returns the steps
   on_abort got, the tools that ran, and whether on_step_finish was
   called. *)
let run_abort_in_tool_batch ?(pause = false) ~abort_in () =
  let model, (_ : Mock.t) =
    make_abort_stream_model ~tool_call_ids:[ "tc_1"; "tc_2" ]
      ~usage:{ input_tokens = 10; output_tokens = 5; total_tokens = Some 15 }
      ~pause ()
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
            let%lwt () =
              match pause with
              | true -> Lwt.pause ()
              | false -> Lwt.return_unit
            in
            if String.equal options.tool_call_id abort_in then abort ();
            Lwt.return (`String "results"));
    }
  in
  let aborted_steps = ref None in
  let step_finished = ref false in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_step_finish:(fun (_ : Ai_core.Generate_text_result.step) -> step_finished := true)
      ~on_abort:(fun ~steps -> aborted_steps := Some steps)
      ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  check_ends_with_abort parts;
  check_result_aborted result;
  Lwt.return (!aborted_steps, List.rev !ran, !step_finished)

(* The abort lands while the first tool runs, so on_abort gets the step with
   no tool result yet, and the second tool never runs. *)
let test_abort_in_first_tool_keeps_step () =
  let%lwt aborted_steps, ran, step_finished = run_abort_in_tool_batch ~abort_in:"tc_1" () in
  check_aborted_step ~tool_results:[] aborted_steps;
  (check (list string)) "tools that ran" [ "tc_1" ] ran;
  (check bool) "on_step_finish not called" false step_finished;
  Lwt.return_unit

(* The first tool's result reaches the step before the second tool fires the
   abort, so on_abort gets that result only. *)
let test_abort_in_second_tool_keeps_first_result () =
  let%lwt aborted_steps, ran, step_finished = run_abort_in_tool_batch ~abort_in:"tc_2" () in
  check_aborted_step ~tool_results:[ "tc_1" ] aborted_steps;
  (check (list string)) "tools that ran" [ "tc_1"; "tc_2" ] ran;
  (check bool) "on_step_finish not called" false step_finished;
  Lwt.return_unit

(* [on_chunk] fires the signal on the first tool's [Tool_result] part. The
   tool returned before that, so its result is in the step [on_abort] and
   [outcome] get, as it is in [full_stream]. The second tool never runs. *)
let test_abort_on_tool_result_part_keeps_result () =
  let model, (_ : Mock.t) =
    make_abort_stream_model ~tool_call_ids:[ "tc_1"; "tc_2" ]
      ~usage:{ input_tokens = 10; output_tokens = 5; total_tokens = Some 15 }
      ()
  in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let runs = ref 0 in
  let tool =
    {
      search_tool with
      execute =
        Some
          (fun (_ : Yojson.Basic.t) _ ->
            incr runs;
            Lwt.return (`String "results"));
    }
  in
  let aborted_steps = ref None in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_chunk:(function
        | Tool_result { tool_call_id = "tc_1"; _ } -> abort ()
        | _ -> ())
      ~on_abort:(fun ~steps -> aborted_steps := Some steps)
      ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  check_ends_with_abort parts;
  (check int) "tool runs" 1 !runs;
  (check int) "tool-result parts" 1
    (List.length
       (List.filter
          (function
            | Ai_core.Text_stream_part.Tool_result _ -> true
            | _ -> false)
          parts));
  check_aborted_step ~tool_results:[ "tc_1" ] !aborted_steps;
  let%lwt outcome = result.outcome in
  (match outcome with
  | Aborted { steps; _ } -> check_aborted_step ~tool_results:[ "tc_1" ] (Some steps)
  | Finished _ | Failed _ -> fail "expected Aborted");
  Lwt.return_unit

(* Telemetry fires the signal while it reports the first tool's result. The
   [Tool_result] part went out before that, so [full_stream] has it, as do
   [on_abort] and [outcome]. *)
let test_abort_in_tool_call_finish_keeps_part () =
  let model, (_ : Mock.t) =
    make_abort_stream_model ~tool_call_ids:[ "tc_1"; "tc_2" ]
      ~usage:{ input_tokens = 10; output_tokens = 5; total_tokens = Some 15 }
      ()
  in
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
  let aborted_steps = ref None in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", search_tool ]
      ~max_steps:3 ~abort_signal:signal ~telemetry
      ~on_abort:(fun ~steps -> aborted_steps := Some steps)
      ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  check_ends_with_abort parts;
  (check (list string))
    "tool-result parts" [ "tc_1" ]
    (List.filter_map
       (function
         | Ai_core.Text_stream_part.Tool_result { tool_call_id; _ } -> Some tool_call_id
         | _ -> None)
       parts);
  check_aborted_step ~tool_results:[ "tc_1" ] !aborted_steps;
  Lwt.return_unit

(* As the two tests above, with the abort coming from inside an Lwt
   callback. The result is the same: a result counts only if its tool
   returned before the signal fired. *)
let test_abort_in_tool_batch_at_depth_1 () =
  let%lwt aborted_steps, ran, (_ : bool) = run_abort_in_tool_batch ~pause:true ~abort_in:"tc_1" () in
  check_aborted_step ~tool_results:[] aborted_steps;
  (check (list string)) "tools that ran" [ "tc_1" ] ran;
  let%lwt aborted_steps, ran, (_ : bool) = run_abort_in_tool_batch ~pause:true ~abort_in:"tc_2" () in
  check_aborted_step ~tool_results:[ "tc_1" ] aborted_steps;
  (check (list string)) "tools that ran" [ "tc_1"; "tc_2" ] ran;
  Lwt.return_unit

(* The provider has sent its [Finish] part, with usage, but not closed the
   stream when the abort lands. The response is complete, so on_abort gets
   its step. *)
let test_abort_after_provider_finish () =
  let model, (_ : Mock.t) =
    Mock.create
      ~stream:(Respond (Mock.hanging_stream [ stream_start; Text { text = "Hi" }; finish_part (tokens 10 5) ]))
      ()
  in
  let aborted_steps = ref None in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello"
      ~abort_signal:(Ai_provider.Abort_signal.of_promise (Lwt_unix.sleep 0.05))
      ~on_abort:(fun ~steps -> aborted_steps := Some steps)
      ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  check_ends_with_abort parts;
  (match !aborted_steps with
  | Some [ step ] ->
    (check string) "text" "Hi" step.text;
    (check int) "input tokens" 10 step.usage.input_tokens
  | Some steps -> failf "expected one step, got %d" (List.length steps)
  | None -> fail "on_abort was not called");
  match%lwt result.outcome with
  | Aborted { steps = [ (_ : Ai_core.Generate_text_result.step) ]; _ } -> Lwt.return_unit
  | Aborted { steps; _ } -> failf "expected one step in outcome, got %d" (List.length steps)
  | Finished _ | Failed _ -> fail "expected Aborted"

(* An exception from on_abort is ignored, and the call still ends with the
   [Abort] part. *)
let test_on_abort_raises () =
  let model, (_ : Mock.t) = make_abort_stream_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", counting_search_tool ~abort (ref 0) ]
      ~max_steps:3 ~abort_signal:signal
      ~on_abort:(fun ~steps:_ -> failwith "on_abort failed")
      ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  check_ends_with_abort parts;
  check_result_aborted result;
  Lwt.return_unit

(* A tool that runs a sub-agent under its own timeout, in a call with no
   signal. The timeout is the tool's error result, and the call finishes. *)
let test_tool_own_timeout_is_error_result () =
  let model, (_ : Mock.t) =
    Mock.create
      ~stream:
        (Sequence
           [
             (stream_start :: tool_call_parts "tc_1") @ [ finish_part ~finish_reason:Tool_calls (tokens 10 5) ];
             [ stream_start; Text { text = "Done" }; finish_part (tokens 1 1) ];
           ])
      ()
  in
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
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Search" ~tools:[ "search", tool ] ~max_steps:2 () in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let errors =
    List.filter_map
      (function
        | Ai_core.Text_stream_part.Tool_result { is_error = true; result = `String text; _ } -> Some text
        | _ -> None)
      parts
  in
  (check (list string)) "error results" [ "Abort_signal.Aborted(Abort_signal.Timeout(0.01s))" ] errors;
  match%lwt result.outcome with
  | Finished _ -> Lwt.return_unit
  | Aborted _ | Failed _ -> fail "expected Finished"

(* A tool that cancels its own work when the signal fires fails with
   [Canceled]. That counts as the abort: on_abort gets the step. *)
let test_tool_cancelling_itself_on_abort () =
  let model, (_ : Mock.t) = make_abort_stream_model () in
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
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", tool ]
      ~max_steps:3
      ~abort_signal:(Ai_provider.Abort_signal.of_promise (Lwt_unix.sleep 0.05))
      ~on_abort:(fun ~steps -> aborted_steps := Some steps)
      ()
  in
  let%lwt parts = Lwt_stream.to_list result.full_stream in
  let%lwt () = Lwt.pause () in
  check_ends_with_abort parts;
  (match !aborted_steps with
  | Some [ { tool_calls = [ _ ]; tool_results = []; _ } ] -> ()
  | Some _ -> fail "expected one step with one call and no result"
  | None -> fail "on_abort was not called");
  Lwt.return_unit

let step_tool_call_ids steps =
  List.concat_map
    (fun (step : Ai_core.Generate_text_result.step) ->
      List.map (fun (tc : Ai_core.Generate_text_result.tool_call) -> tc.tool_call_id) step.tool_calls)
    steps

(* Recording each step before its tools run reports it once, in [steps] and
   in on_abort. *)
let test_steps_reported_once () =
  let result =
    Ai_core.Stream_text.stream_text ~model:(make_multi_step_stream_model ()) ~prompt:"Go"
      ~tools:[ "search", search_tool ]
      ~max_steps:10
      ~stop_when:[ Ai_core.Stop_condition.step_count_is 3 ]
      ()
  in
  let (_ : Ai_core.Text_stream_part.t list) = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (check (list string)) "steps" [ "tc_1"; "tc_2"; "tc_3" ] (step_tool_call_ids (Lwt_main.run result.steps));
  let signal, abort = Ai_provider.Abort_signal.create () in
  let finished_steps = ref 0 in
  let aborted_steps = ref None in
  let result =
    Ai_core.Stream_text.stream_text ~model:(make_multi_step_stream_model ()) ~prompt:"Go"
      ~tools:[ "search", search_tool ]
      ~max_steps:10 ~abort_signal:signal
      ~on_step_finish:(fun (_ : Ai_core.Generate_text_result.step) ->
        incr finished_steps;
        if Int.equal !finished_steps 2 then abort ())
      ~on_abort:(fun ~steps -> aborted_steps := Some (step_tool_call_ids steps))
      ()
  in
  let (_ : Ai_core.Text_stream_part.t list) = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (check (option (list string))) "on_abort steps" (Some [ "tc_1"; "tc_2" ]) !aborted_steps

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
  let model = make_multi_step_stream_model () in
  let signal, _abort = Ai_provider.Abort_signal.create () in
  let seen = ref [] in
  let result =
    Ai_core.Stream_text.stream_text ~model ~system:"Be brief" ~prompt:"Search"
      ~tools:[ "search", recording_search_tool seen ]
      ~max_steps:3 ~abort_signal:signal ()
  in
  let%lwt (_ : Ai_core.Text_stream_part.t list) = Lwt_stream.to_list result.full_stream in
  let runs = List.rev !seen in
  (check (list string))
    "tool call ids" [ "tc_1"; "tc_2" ]
    (List.map (fun (options : Ai_core.Core_tool.execute_options) -> options.tool_call_id) runs);
  (check (list (list string)))
    "messages"
    [ [ "user" ]; [ "user"; "assistant"; "tool" ] ]
    (List.map (fun (options : Ai_core.Core_tool.execute_options) -> roles options.messages) runs);
  (check (list bool)) "signal" [ true; true ] (List.map (has_signal signal) runs);
  Lwt.return_unit

(* An approved pending tool runs before the first step and gets the request's
   messages. *)
let test_pending_tool_execute_options () =
  let model = make_tool_stream_model () in
  let signal, _abort = Ai_provider.Abort_signal.create () in
  let seen = ref [] in
  let pending : Ai_core.Generate_text_result.pending_tool_approval =
    { tool_call_id = "tc_0"; tool_name = "search"; args = `Assoc []; approved = true }
  in
  let messages : Ai_provider.Prompt.message list =
    [
      User { content = [ Text { text = "Search"; provider_options = Ai_provider.Provider_options.empty } ] };
      Assistant
        {
          content =
            [
              Tool_call
                {
                  id = "tc_0";
                  name = "search";
                  args = `Assoc [];
                  provider_options = Ai_provider.Provider_options.empty;
                };
            ];
        };
    ]
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~system:"Be brief" ~messages
      ~tools:[ "search", recording_search_tool seen ]
      ~pending_tool_approvals:[ pending ] ~max_steps:2 ~abort_signal:signal ()
  in
  let%lwt (_ : Ai_core.Text_stream_part.t list) = Lwt_stream.to_list result.full_stream in
  (match !seen with
  | [ options ] ->
    (check string) "tool call id" "tc_0" options.tool_call_id;
    (check (list string)) "messages" [ "user"; "assistant" ] (roles options.messages);
    (check bool) "signal" true (has_signal signal options)
  | runs -> Alcotest.failf "expected one run, got %d" (List.length runs));
  Lwt.return_unit

(* The abort path ignores exceptions from [on_chunk] and still closes. *)
let test_abort_on_chunk_raises () =
  let model, (_ : Mock.t) = make_abort_stream_model () in
  let aborted = ref false in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~abort_signal:(Ai_provider.Abort_signal.of_promise Lwt.return_unit)
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
  let model, (_ : Mock.t) =
    Mock.create
      ~stream:
        (Respond
           (fun (_ : Ai_provider.Call_options.t) ->
             Lwt.return { Ai_provider.Stream_result.stream = provider_stream; warnings = []; raw_response = None }))
      ()
  in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"x" ~abort_signal:signal
      ~on_chunk:(function
        | Text_delta _ -> abort ()
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
  let model, (_ : Mock.t) = make_abort_stream_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
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
        | Text_delta _ -> abort ()
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
  let model, (_ : Mock.t) =
    Mock.create ~stream:(Respond (fun (_ : Ai_provider.Call_options.t) -> Lwt.fail_with "provider down")) ()
  in
  let chunks = ref [] in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~max_retries:0
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
  (check bool) "output fails with the provider error" true (failed_with_failure "provider down" result.output);
  (check bool) "provider_metadata fails with the provider error" true
    (failed_with_failure "provider down" result.provider_metadata);
  Lwt.return_unit

(* A custom model that ignores the abort signal: its stream sends one text part
   and then neither pushes nor closes. *)
let make_stalled_model () =
  fst (Mock.create ~stream:(Respond (Mock.hanging_stream ~ignore_abort:true [ stream_start; Text { text = "Hi" } ])) ())

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
      (let signal, abort = Ai_provider.Abort_signal.create () in
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
       abort ();
       let%lwt parts = to_list_or_hang result.full_stream in
       let%lwt () = Lwt_unix.sleep 0.1 in
       (check (option (list string))) "parts after the abort" (Some [ "abort" ]) (Option.map (List.map part_name) parts);
       (check bool) "ai.streamText span ended" true (List.mem "ai.streamText" !exited);
       (check bool) "ai.streamText.doStream span ended" true (List.mem "ai.streamText.doStream" !exited);
       Lwt.return_unit))

(* Races between the transitions that end the call. Whichever comes first
   settles the streams and promises, and the other does nothing. *)

let last_part_name parts = Option.bind parts (fun parts -> Option.map part_name (List.nth_opt (List.rev parts) 0))

(* The call has finished when [on_finish] runs, so an abort from there is too
   late. *)
let test_finish_then_abort () =
  let model = make_text_stream_model "Hi" in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let on_abort_calls = ref 0 in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~abort_signal:signal
      ~on_finish:(fun (_ : Ai_core.Generate_text_result.t) -> abort ~reason:Exit ())
      ~on_abort:(fun ~steps:_ -> incr on_abort_calls)
      ()
  in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  (check bool) "signal fired" true (Ai_provider.Abort_signal.is_aborted signal);
  (check (option string)) "last part" (Some "finish") (last_part_name parts);
  (check int) "on_abort not called" 0 !on_abort_calls;
  let%lwt usage = result.usage in
  let%lwt finish_reason = result.finish_reason in
  let%lwt steps = result.steps in
  (check int) "usage" 10 usage.input_tokens;
  (check string) "finish reason" "stop" (Ai_provider.Finish_reason.to_string finish_reason);
  (check int) "one step" 1 (List.length steps);
  Lwt.return_unit

(* An abort from [on_step_finish] on the final step comes before the finish,
   so the call ends with [Abort] and never finishes. *)
let test_abort_then_finish () =
  let model = make_text_stream_model "Hi" in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let on_abort_steps = ref [] in
  let finished = ref false in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~abort_signal:signal
      ~on_step_finish:(fun (_ : Ai_core.Generate_text_result.step) -> abort ())
      ~on_finish:(fun (_ : Ai_core.Generate_text_result.t) -> finished := true)
      ~on_abort:(fun ~steps -> on_abort_steps := List.length steps :: !on_abort_steps)
      ()
  in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  (check (option (list string)))
    "parts"
    (Some [ "start"; "start-step"; "text-start"; "text-delta"; "text-delta"; "text-end"; "finish-step"; "abort" ])
    (Option.map (List.map part_name) parts);
  (check (list int)) "on_abort called once with the step" [ 1 ] !on_abort_steps;
  (check bool) "on_finish not called" false !finished;
  check_result_aborted result;
  Lwt.return_unit

(* A model whose stream call fails with [message]. When [after_abort], it
   first waits for the abort signal in its call options. *)
let make_failing_stream_model ~after_abort message =
  let respond (options : Ai_provider.Call_options.t) =
    match after_abort, options.abort_signal with
    | true, Some signal ->
      let%lwt () = Ai_provider.Abort_signal.wait signal in
      Lwt.fail_with message
    | true, None | false, (Some _ | None) -> Lwt.fail_with message
  in
  fst (Mock.create ~stream:(Respond respond) ())

(* The error settles the call before [on_chunk] sees the [Error] part, so an
   abort from there does nothing. *)
let test_error_then_abort () =
  let model = make_failing_stream_model ~after_abort:false "provider down" in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let on_abort_calls = ref 0 in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~max_retries:0 ~abort_signal:signal
      ~on_chunk:(function
        | Error _ -> abort ~reason:Exit ()
        | _ -> ())
      ~on_abort:(fun ~steps:_ -> incr on_abort_calls)
      ()
  in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  (check bool) "signal fired" true (Ai_provider.Abort_signal.is_aborted signal);
  (check (option (list string)))
    "parts"
    (Some [ "start"; "start-step"; "error" ])
    (Option.map (List.map part_name) parts);
  (check int) "on_abort not called" 0 !on_abort_calls;
  (check bool) "usage fails with the provider error" true (failed_with_failure "provider down" result.usage);
  (check bool) "steps fails with the provider error" true (failed_with_failure "provider down" result.steps);
  Lwt.return_unit

(* The model fails only after the abort, so its error is a side effect of the
   abort and is not reported. *)
let test_abort_then_error () =
  let model = make_failing_stream_model ~after_abort:true "provider down" in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let on_abort_calls = ref 0 in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~max_retries:0 ~abort_signal:signal
      ~on_abort:(fun ~steps:_ -> incr on_abort_calls)
      ()
  in
  let%lwt (_ : Ai_core.Text_stream_part.t list) =
    read_until
      (function
        | Ai_core.Text_stream_part.Start_step -> true
        | _ -> false)
      result.full_stream ~acc:[]
  in
  abort ~reason:Exit ();
  let%lwt rest = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  (check (option (list string)))
    "parts after the abort" (Some [ "abort:Stdlib.Exit" ])
    (Option.map (List.map part_name) rest);
  (check int) "on_abort called once" 1 !on_abort_calls;
  (check bool) "usage fails with Aborted and the reason" true
    (match Lwt.state result.usage with
    | Lwt.Fail (Ai_provider.Abort_signal.Aborted { reason = Some Exit }) -> true
    | Lwt.Fail _ | Lwt.Return _ | Lwt.Sleep -> false);
  check_result_aborted result;
  Lwt.return_unit

(* A model that gives the same two steps to [generate] and [stream]: a
   search tool call, then text. *)
let make_scripted_model () =
  let generate =
    [
      Mock.generate_result ~finish_reason:Tool_calls ~usage:(tokens 10 8)
        [
          Tool_call
            { tool_call_type = "function"; tool_call_id = "tc_1"; tool_name = "search"; args = {|{"query":"test"}|} };
        ];
      Mock.generate_result ~usage:(tokens 20 5) [ Text { text = "Found it!" } ];
    ]
  in
  let stream =
    [
      (stream_start :: tool_call_parts "tc_1") @ [ finish_part ~finish_reason:Tool_calls (tokens 10 8) ];
      [ stream_start; Text { text = "Found it!" }; finish_part (tokens 20 5) ];
    ]
  in
  fst (Mock.create ~generate:(Sequence generate) ~stream:(Sequence stream) ())

let tool_call_ids (result : Ai_core.Generate_text_result.t) =
  List.map (fun (tc : Ai_core.Generate_text_result.tool_call) -> tc.tool_call_id) result.tool_calls

let tool_result_ids (result : Ai_core.Generate_text_result.t) =
  List.map (fun (tr : Ai_core.Generate_text_result.tool_result) -> tr.tool_call_id) result.tool_results

(* A finished call's outcome holds the result [on_finish] gets, and it
   matches what [generate_text] returns for the same model script. *)
let test_outcome_finished () =
  let finished = ref None in
  let result =
    Ai_core.Stream_text.stream_text ~model:(make_scripted_model ()) ~prompt:"Search"
      ~tools:[ "search", search_tool ]
      ~max_steps:3
      ~on_finish:(fun result -> finished := Some result)
      ()
  in
  let%lwt (_ : Ai_core.Text_stream_part.t list option) = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  let%lwt generated =
    Ai_core.Generate_text.generate_text ~model:(make_scripted_model ()) ~prompt:"Search"
      ~tools:[ "search", search_tool ]
      ~max_steps:3 ()
  in
  match Lwt.state result.outcome with
  | Lwt.Return (Finished streamed) ->
    (check bool) "on_finish got the same result" true
      (match !finished with
      | Some on_finish_result -> on_finish_result == streamed
      | None -> false);
    (check string) "text" generated.text streamed.text;
    (check string) "text value" "Found it!" streamed.text;
    (check int) "steps" (List.length generated.steps) (List.length streamed.steps);
    (check int) "two steps" 2 (List.length streamed.steps);
    (check int) "input tokens" generated.usage.input_tokens streamed.usage.input_tokens;
    (check int) "output tokens" generated.usage.output_tokens streamed.usage.output_tokens;
    (check (option int)) "total tokens" generated.usage.total_tokens streamed.usage.total_tokens;
    (check (option int)) "total tokens value" (Some 43) streamed.usage.total_tokens;
    (check string) "finish reason"
      (Ai_provider.Finish_reason.to_string generated.finish_reason)
      (Ai_provider.Finish_reason.to_string streamed.finish_reason);
    (check (list string)) "tool calls" (tool_call_ids generated) (tool_call_ids streamed);
    (check (list string)) "tool results" (tool_result_ids generated) (tool_result_ids streamed);
    Lwt.return_unit
  | Lwt.Return (Aborted _ | Failed _) | Lwt.Fail _ | Lwt.Sleep -> fail "expected Finished"

(* An abort in the second step: the outcome holds the first step, the steps
   on_abort got, and the signal's reason. *)
let test_outcome_aborted_with_steps () =
  let model, (_ : Mock.t) = make_abort_stream_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let aborted_steps = ref None in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", search_tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_abort:(fun ~steps -> aborted_steps := Some steps)
      ()
  in
  let%lwt (_ : Ai_core.Text_stream_part.t list) =
    read_until
      (function
        | Ai_core.Text_stream_part.Text_delta _ -> true
        | _ -> false)
      result.full_stream ~acc:[]
  in
  abort ~reason:Exit ();
  let%lwt (_ : Ai_core.Text_stream_part.t list option) = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  match Lwt.state result.outcome with
  | Lwt.Return (Aborted { steps = [ step ] as steps; reason = Some Exit }) ->
    (check bool) "on_abort got the same steps" true
      (match !aborted_steps with
      | Some reported -> reported == steps
      | None -> false);
    (check int) "step input tokens" 10 step.usage.input_tokens;
    (check (list string))
      "step tool results" [ "tc_1" ]
      (List.map (fun (tr : Ai_core.Generate_text_result.tool_result) -> tr.tool_call_id) step.tool_results);
    Lwt.return_unit
  | Lwt.Return (Aborted { steps; reason = _ }) ->
    failf "expected one step and reason Exit, got %d steps" (List.length steps)
  | Lwt.Return (Finished _ | Failed _) | Lwt.Fail _ | Lwt.Sleep -> fail "expected Aborted"

(* A signal that fired before the call: no step, and the reason. *)
let test_outcome_aborted_before_any_step () =
  let model = make_text_stream_model "Hello" in
  let signal, abort = Ai_provider.Abort_signal.create () in
  abort ~reason:Exit ();
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~abort_signal:signal () in
  let%lwt (_ : Ai_core.Text_stream_part.t list option) = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  (check bool) "outcome" true
    (match Lwt.state result.outcome with
    | Lwt.Return (Aborted { steps = []; reason = Some Exit }) -> true
    | Lwt.Return (Aborted _ | Finished _ | Failed _) | Lwt.Fail _ | Lwt.Sleep -> false);
  Lwt.return_unit

(* A failed call's outcome holds the exception the result promises fail
   with. *)
let test_outcome_failed () =
  let model = make_failing_stream_model ~after_abort:false "provider down" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~max_retries:0 () in
  let%lwt (_ : Ai_core.Text_stream_part.t list option) = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  (check bool) "outcome holds the exception usage fails with" true
    (match Lwt.state result.outcome, Lwt.state result.usage with
    | Lwt.Return (Failed (Failure message as outcome_exn)), Lwt.Fail usage_exn ->
      String.equal message "provider down" && outcome_exn == usage_exn
    | Lwt.Return (Failed _ | Finished _ | Aborted _), _ | (Lwt.Fail _ | Lwt.Sleep), _ -> false);
  Lwt.return_unit

(* A provider error inside a step gives an [Error] part, and the step goes
   on to [Finish_step] and [Finish]. That is why [is_terminal] is false for
   [Error]. *)
let test_provider_error_part_not_terminal () =
  let error = Ai_provider.Provider_error.make_api_error ~provider:"mock" ~status:500 ~body:"boom" () in
  let model, (_ : Mock.t) =
    Mock.create ~stream:(Return [ stream_start; Text { text = "Hi" }; Error { error }; finish_part (tokens 1 1) ]) ()
  in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" () in
  let%lwt parts = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  let parts = Option.value ~default:[] parts in
  (check (list string))
    "parts"
    [ "start"; "start-step"; "text-start"; "text-delta"; "error"; "text-end"; "finish-step"; "finish" ]
    (List.map part_name parts);
  (check (list string))
    "only the last part is terminal" [ "finish" ]
    (List.map part_name (List.filter Ai_core.Text_stream_part.is_terminal parts));
  (check bool) "outcome is Finished" true
    (match Lwt.state result.outcome with
    | Lwt.Return (Finished _) -> true
    | Lwt.Return (Aborted _ | Failed _) | Lwt.Fail _ | Lwt.Sleep -> false);
  Lwt.return_unit

let test_is_terminal () =
  let usage = { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = None } in
  let parts : (Ai_core.Text_stream_part.t * bool) list =
    [
      Start, false;
      Start_step, false;
      Text_start { id = "t" }, false;
      Text_delta { id = "t"; text = "x" }, false;
      Text_end { id = "t" }, false;
      Reasoning_start { id = "r"; provider_metadata = None }, false;
      Reasoning_delta { id = "r"; text = "x"; provider_metadata = None }, false;
      Reasoning_end { id = "r"; provider_metadata = None }, false;
      Tool_call { tool_call_id = "tc"; tool_name = "search"; args = `Null }, false;
      Tool_call_delta { tool_call_id = "tc"; tool_name = "search"; args_text_delta = "" }, false;
      ( Tool_result
          { tool_call_id = "tc"; tool_name = "search"; result = `Null; is_error = false; provider_metadata = None },
        false );
      Tool_output_denied { tool_call_id = "tc" }, false;
      Tool_approval_request { approval_id = "a"; tool_call_id = "tc"; tool_name = "search"; args = `Null }, false;
      Source { source_id = "s"; url = "https://example.com"; title = None }, false;
      File { url = "https://example.com/f"; media_type = "text/plain" }, false;
      Finish_step { finish_reason = Stop; usage }, false;
      Finish { finish_reason = Stop; usage }, true;
      Error { error = "boom" }, false;
      Abort { reason = None }, true;
    ]
  in
  List.iter
    (fun (part, expected) -> (check bool) (part_name part) expected (Ai_core.Text_stream_part.is_terminal part))
    parts

(* on_abort runs before any result promise rejects and before [outcome]
   resolves. The abort hook runs inside an Lwt callback, which defers the
   promises' callbacks anyway, so on_abort also checks that each promise is
   still pending: their state changes at once. *)
let test_on_abort_before_promises_settle () =
  let model, (_ : Mock.t) = make_abort_stream_model () in
  let signal, abort = Ai_provider.Abort_signal.create () in
  let events = ref [] in
  let record event = events := event :: !events in
  let result_ref = ref None in
  let all_pending (result : Ai_core.Stream_text_result.t) =
    Lwt.is_sleeping result.usage
    && Lwt.is_sleeping result.finish_reason
    && Lwt.is_sleeping result.steps
    && Lwt.is_sleeping result.output
    && Lwt.is_sleeping result.provider_metadata
    && Lwt.is_sleeping result.outcome
  in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search"
      ~tools:[ "search", search_tool ]
      ~max_steps:3 ~abort_signal:signal
      ~on_abort:(fun ~steps:(_ : Ai_core.Generate_text_result.step list) ->
        match Option.map all_pending !result_ref with
        | Some true -> record "on_abort"
        | Some false -> record "on_abort after a promise settled"
        | None -> record "on_abort before stream_text returned")
      ()
  in
  result_ref := Some result;
  let on_failure name promise = Lwt.on_failure promise (fun (_ : exn) -> record name) in
  on_failure "usage" result.usage;
  on_failure "finish_reason" result.finish_reason;
  on_failure "steps" result.steps;
  on_failure "output" result.output;
  on_failure "provider_metadata" result.provider_metadata;
  Lwt.on_success result.outcome (fun (_ : Ai_core.Stream_text_result.outcome) -> record "outcome");
  let%lwt (_ : Ai_core.Text_stream_part.t list) =
    read_until
      (function
        | Ai_core.Text_stream_part.Text_delta _ -> true
        | _ -> false)
      result.full_stream ~acc:[]
  in
  (check (list string)) "nothing settled before the abort" [] !events;
  abort ();
  let%lwt (_ : Ai_core.Text_stream_part.t list option) = to_list_or_hang result.full_stream in
  let%lwt () = Lwt.pause () in
  (check (list string))
    "order"
    [ "on_abort"; "usage"; "finish_reason"; "steps"; "output"; "provider_metadata"; "outcome" ]
    (List.rev !events);
  Lwt.return_unit

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
          test_case "execute_options" `Quick (run_lwt test_tool_execute_options);
          test_case "pending_execute_options" `Quick (run_lwt test_pending_tool_execute_options);
          test_case "approval_stops_stream_loop" `Quick test_approval_stops_stream_loop;
          test_case "approved_tool_executes" `Quick test_approved_tool_executes_stream;
          test_case "denied_emits_output_denied" `Quick test_denied_tool_emits_output_denied;
          test_case "mixed_tools_safe_executes" `Quick test_mixed_tools_safe_executes_stream;
        ] );
      ( "callbacks",
        [
          test_case "on_chunk" `Quick test_on_chunk_callback;
          test_case "on_chunk_raises_on_finish" `Quick (run_lwt test_on_chunk_raises_on_finish);
          test_case "abort_from_on_chunk_on_finish" `Quick (run_lwt test_abort_from_on_chunk_on_finish);
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
          test_case "reason" `Quick (run_lwt test_abort_reason);
          test_case "after_finish" `Quick (run_lwt test_abort_after_finish);
          test_case "in_on_step_finish" `Quick (run_lwt test_abort_in_on_step_finish);
          test_case "during_tool" `Quick (run_lwt test_abort_during_tool);
          test_case "ui_stream" `Quick (run_lwt test_abort_ui_stream);
          test_case "on_chunk_raises" `Quick (run_lwt test_abort_on_chunk_raises);
          test_case "between_tools" `Quick (run_lwt test_abort_between_tools);
          test_case "between_pending_approvals" `Quick (run_lwt test_abort_between_pending_approvals);
          test_case "in_first_tool_keeps_step" `Quick (run_lwt test_abort_in_first_tool_keeps_step);
          test_case "in_second_tool_keeps_first_result" `Quick (run_lwt test_abort_in_second_tool_keeps_first_result);
          test_case "on_tool_result_part_keeps_result" `Quick (run_lwt test_abort_on_tool_result_part_keeps_result);
          test_case "in_tool_call_finish_keeps_part" `Quick (run_lwt test_abort_in_tool_call_finish_keeps_part);
          test_case "in_tool_batch_at_depth_1" `Quick (run_lwt test_abort_in_tool_batch_at_depth_1);
          test_case "after_provider_finish" `Quick (run_lwt test_abort_after_provider_finish);
          test_case "on_abort_raises" `Quick (run_lwt test_on_abort_raises);
          test_case "tool_own_timeout_is_error_result" `Quick (run_lwt test_tool_own_timeout_is_error_result);
          test_case "tool_cancelling_itself" `Quick (run_lwt test_tool_cancelling_itself_on_abort);
          test_case "steps_reported_once" `Quick test_steps_reported_once;
          test_case "stops_reading_provider" `Quick (run_lwt test_abort_stops_reading_provider);
          test_case "after_pending_approvals" `Quick (run_lwt test_abort_after_pending_approvals);
          test_case "stalled_provider" `Quick test_abort_with_stalled_provider;
        ] );
      ( "ending_races",
        [
          test_case "finish_then_abort" `Quick (run_lwt test_finish_then_abort);
          test_case "abort_then_finish" `Quick (run_lwt test_abort_then_finish);
          test_case "error_then_abort" `Quick (run_lwt test_error_then_abort);
          test_case "abort_then_error" `Quick (run_lwt test_abort_then_error);
        ] );
      ( "outcome",
        [
          test_case "finished" `Quick (run_lwt test_outcome_finished);
          test_case "aborted_with_steps" `Quick (run_lwt test_outcome_aborted_with_steps);
          test_case "aborted_before_any_step" `Quick (run_lwt test_outcome_aborted_before_any_step);
          test_case "failed" `Quick (run_lwt test_outcome_failed);
          test_case "on_abort_before_promises_settle" `Quick (run_lwt test_on_abort_before_promises_settle);
        ] );
      ( "terminal_parts",
        [
          test_case "is_terminal" `Quick test_is_terminal;
          test_case "provider_error_part_not_terminal" `Quick (run_lwt test_provider_error_part_not_terminal);
        ] );
    ]
