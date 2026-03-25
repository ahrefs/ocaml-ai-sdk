open Melange_json.Primitives
open Alcotest

type query_args = { query : string } [@@json.allow_extra_fields] [@@deriving of_json]

(* Core_tool tests *)
let test_tool_construction () =
  let tool : Ai_core.Core_tool.t =
    {
      description = Some "Search the web";
      parameters = `Assoc [ "type", `String "object" ];
      execute = (fun _args -> Lwt.return (`String "result"));
    }
  in
  (check (option string)) "description" (Some "Search the web") tool.description

let test_tool_execute () =
  let tool : Ai_core.Core_tool.t =
    {
      description = None;
      parameters = `Null;
      execute =
        (fun args ->
          let q = (query_args_of_json args).query in
          Lwt.return (`String (Printf.sprintf "Found: %s" q)));
    }
  in
  let result = Lwt_main.run (tool.execute (`Assoc [ "query", `String "ocaml" ])) in
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

let test_step_construction () =
  let step : Ai_core.Generate_text_result.step =
    {
      text = "Hello";
      reasoning = "";
      tool_calls = [];
      tool_results = [];
      finish_reason = Ai_provider.Finish_reason.Stop;
      usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
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
      Tool_result { tool_call_id = "tc_1"; tool_name = "search"; result = `String "found"; is_error = false };
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
          test_case "step" `Quick test_step_construction;
          test_case "result" `Quick test_result_construction;
        ] );
      ( "text_stream_part",
        [ test_case "basic_parts" `Quick test_stream_parts; test_case "tool_parts" `Quick test_tool_stream_parts ] );
    ]
