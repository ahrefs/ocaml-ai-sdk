open Melange_json.Primitives
open Alcotest

type query_args = { query : string } [@@json.allow_extra_fields] [@@deriving of_json]

(* Core_tool tests *)
let test_tool_construction () =
  let tool : Ai_core.Core_tool.t =
    {
      description = Some "Search the web";
      parameters = `Assoc [ "type", `String "object" ];
      execute = Some (fun _args _ -> Lwt.return (`String "result"));
      needs_approval = None;
      provider_options = Ai_provider.Provider_options.empty;
    }
  in
  (check (option string)) "description" (Some "Search the web") tool.description

let test_tool_execute () =
  let tool : Ai_core.Core_tool.t =
    {
      description = None;
      parameters = `Null;
      execute =
        Some
          (fun args _ ->
            let q = (query_args_of_json args).query in
            Lwt.return (`String (Printf.sprintf "Found: %s" q)));
      needs_approval = None;
      provider_options = Ai_provider.Provider_options.empty;
    }
  in
  let exec =
    match tool.execute with
    | Some f -> f
    | None -> failwith "expected execute"
  in
  let options = Ai_core.Core_tool.execute_options ~tool_call_id:"tc_1" () in
  (check int) "messages default" 0 (List.length options.messages);
  (check bool) "abort_signal default" true (Option.is_none options.abort_signal);
  let result = Lwt_main.run (exec (`Assoc [ "query", `String "ocaml" ]) options) in
  (check string) "result" {|"Found: ocaml"|} (Yojson.Basic.to_string result)

(* Generate_text_result tests *)
let test_add_usage () =
  let a : Ai_provider.Usage.t = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 } in
  let b : Ai_provider.Usage.t = { input_tokens = 20; output_tokens = 10; total_tokens = Some 30 } in
  let sum = Ai_core.Generate_text_result.add_usage a b in
  (check int) "input" 30 sum.input_tokens;
  (check int) "output" 15 sum.output_tokens;
  (check (option int)) "total" (Some 45) sum.total_tokens

let test_add_usage_no_total () =
  let a : Ai_provider.Usage.t = { input_tokens = 10; output_tokens = 5; total_tokens = None } in
  let b : Ai_provider.Usage.t = { input_tokens = 20; output_tokens = 10; total_tokens = None } in
  let sum = Ai_core.Generate_text_result.add_usage a b in
  (check int) "input" 30 sum.input_tokens;
  (check int) "output" 15 sum.output_tokens;
  (check (option int)) "total" (Some 45) sum.total_tokens

(* Only one side has a total. The other counts as its input plus output, so
   the order does not matter. *)
let test_add_usage_one_total () =
  let a : Ai_provider.Usage.t = { input_tokens = 10; output_tokens = 5; total_tokens = Some 20 } in
  let b : Ai_provider.Usage.t = { input_tokens = 20; output_tokens = 10; total_tokens = None } in
  (check (option int)) "a + b" (Some 50) (Ai_core.Generate_text_result.add_usage a b).total_tokens;
  (check (option int)) "b + a" (Some 50) (Ai_core.Generate_text_result.add_usage b a).total_tokens

let step_with_usage (usage : Ai_provider.Usage.t) : Ai_core.Generate_text_result.step =
  {
    text = "";
    reasoning = "";
    tool_calls = [];
    tool_results = [];
    finish_reason = Ai_provider.Finish_reason.Stop;
    usage;
    response_model = None;
    provider_metadata = None;
  }

let check_usage ~input ~output ~total (usage : Ai_provider.Usage.t) =
  (check int) "input" input usage.input_tokens;
  (check int) "output" output usage.output_tokens;
  (check (option int)) "total" total usage.total_tokens

let test_total_usage_steps () =
  let steps =
    List.map step_with_usage
      [
        { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
        { input_tokens = 20; output_tokens = 10; total_tokens = Some 30 };
        { input_tokens = 1; output_tokens = 2; total_tokens = Some 4 };
      ]
  in
  (* The reported totals are summed, even where one differs from input plus
     output. *)
  check_usage ~input:31 ~output:17 ~total:(Some 49) (Ai_core.Generate_text_result.total_usage steps)

let test_total_usage_missing_total () =
  let steps =
    List.map step_with_usage
      [
        { input_tokens = 10; output_tokens = 5; total_tokens = Some 100 };
        { input_tokens = 20; output_tokens = 10; total_tokens = None };
        { input_tokens = 1; output_tokens = 2; total_tokens = Some 4 };
      ]
  in
  (* As in [add_usage], the step with no total counts as its input plus
     output (30), so the total is 100 + 30 + 4 in either order. *)
  check_usage ~input:31 ~output:17 ~total:(Some 134) (Ai_core.Generate_text_result.total_usage steps);
  check_usage ~input:31 ~output:17 ~total:(Some 134) (Ai_core.Generate_text_result.total_usage (List.rev steps))

let test_step_construction () =
  let step : Ai_core.Generate_text_result.step =
    {
      text = "Hello";
      reasoning = "";
      tool_calls = [];
      tool_results = [];
      finish_reason = Ai_provider.Finish_reason.Stop;
      usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
      response_model = None;
      provider_metadata = None;
    }
  in
  (check string) "text" "Hello" step.text;
  (check int) "no tools" 0 (List.length step.tool_calls)

let test_result_construction () =
  let result : Ai_core.Generate_text_result.t =
    {
      text = "Hello world";
      reasoning = "";
      tool_calls = [];
      tool_results = [];
      steps = [];
      finish_reason = Ai_provider.Finish_reason.Stop;
      usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
      response = { id = Some "r1"; model = Some "test"; headers = []; body = `Null };
      warnings = [];
      output = None;
    }
  in
  (check string) "text" "Hello world" result.text

(* Text_stream_part tests *)
let test_stream_parts () =
  let parts : Ai_core.Text_stream_part.t list =
    [
      Start;
      Start_step;
      Text_start { id = "txt_1" };
      Text_delta { id = "txt_1"; text = "Hello" };
      Text_end { id = "txt_1" };
      Finish_step { finish_reason = Stop; usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 } };
      Finish { finish_reason = Stop; usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 } };
    ]
  in
  (check int) "7 parts" 7 (List.length parts)

let test_tool_stream_parts () =
  let parts : Ai_core.Text_stream_part.t list =
    [
      Tool_call_delta { tool_call_id = "tc_1"; tool_name = "search"; args_text_delta = {|{"query":|} };
      Tool_call { tool_call_id = "tc_1"; tool_name = "search"; args = `Assoc [ "query", `String "test" ] };
      Tool_result
        {
          tool_call_id = "tc_1";
          tool_name = "search";
          result = `String "found";
          is_error = false;
          provider_metadata = None;
        };
    ]
  in
  (check int) "3 parts" 3 (List.length parts)

let () =
  run "Core_types"
    [
      ( "core_tool",
        [ test_case "construction" `Quick test_tool_construction; test_case "execute" `Quick test_tool_execute ] );
      ( "generate_text_result",
        [
          test_case "add_usage" `Quick test_add_usage;
          test_case "add_usage_no_total" `Quick test_add_usage_no_total;
          test_case "add_usage_one_total" `Quick test_add_usage_one_total;
          test_case "total_usage_steps" `Quick test_total_usage_steps;
          test_case "total_usage_missing_total" `Quick test_total_usage_missing_total;
          test_case "step" `Quick test_step_construction;
          test_case "result" `Quick test_result_construction;
        ] );
      ( "text_stream_part",
        [ test_case "basic_parts" `Quick test_stream_parts; test_case "tool_parts" `Quick test_tool_stream_parts ] );
    ]
