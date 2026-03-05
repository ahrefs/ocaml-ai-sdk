(* Core_tool tests *)
let test_tool_construction () =
  let tool : Ai_core.Core_tool.t =
    {
      description = Some "Search the web";
      parameters = `Assoc [ "type", `String "object" ];
      execute = (fun _args -> Lwt.return (`String "result"));
    }
  in
  Alcotest.(check (option string)) "description" (Some "Search the web") tool.description

let test_tool_execute () =
  let tool : Ai_core.Core_tool.t =
    {
      description = None;
      parameters = `Null;
      execute =
        (fun args ->
          let q = Yojson.Safe.Util.(member "query" args |> to_string) in
          Lwt.return (`String (Printf.sprintf "Found: %s" q)));
    }
  in
  let result = Lwt_main.run (tool.execute (`Assoc [ "query", `String "ocaml" ])) in
  Alcotest.(check string) "result" {|"Found: ocaml"|} (Yojson.Safe.to_string result)

(* Generate_text_result tests *)
let test_add_usage () =
  let a : Ai_provider.Usage.t = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 } in
  let b : Ai_provider.Usage.t = { input_tokens = 20; output_tokens = 10; total_tokens = Some 30 } in
  let sum = Ai_core.Generate_text_result.add_usage a b in
  Alcotest.(check int) "input" 30 sum.input_tokens;
  Alcotest.(check int) "output" 15 sum.output_tokens;
  Alcotest.(check (option int)) "total" (Some 45) sum.total_tokens

let test_add_usage_no_total () =
  let a : Ai_provider.Usage.t = { input_tokens = 10; output_tokens = 5; total_tokens = None } in
  let b : Ai_provider.Usage.t = { input_tokens = 20; output_tokens = 10; total_tokens = None } in
  let sum = Ai_core.Generate_text_result.add_usage a b in
  Alcotest.(check int) "input" 30 sum.input_tokens;
  Alcotest.(check int) "output" 15 sum.output_tokens;
  Alcotest.(check (option int)) "total" (Some 45) sum.total_tokens

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
  Alcotest.(check string) "text" "Hello" step.text;
  Alcotest.(check int) "no tools" 0 (List.length step.tool_calls)

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
    }
  in
  Alcotest.(check string) "text" "Hello world" result.text

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
  Alcotest.(check int) "7 parts" 7 (List.length parts)

let test_tool_stream_parts () =
  let parts : Ai_core.Text_stream_part.t list =
    [
      Tool_call_delta { tool_call_id = "tc_1"; tool_name = "search"; args_text_delta = {|{"query":|} };
      Tool_call { tool_call_id = "tc_1"; tool_name = "search"; args = `Assoc [ "query", `String "test" ] };
      Tool_result { tool_call_id = "tc_1"; tool_name = "search"; result = `String "found"; is_error = false };
    ]
  in
  Alcotest.(check int) "3 parts" 3 (List.length parts)

let () =
  Alcotest.run "Core_types"
    [
      ( "core_tool",
        [
          Alcotest.test_case "construction" `Quick test_tool_construction;
          Alcotest.test_case "execute" `Quick test_tool_execute;
        ] );
      ( "generate_text_result",
        [
          Alcotest.test_case "add_usage" `Quick test_add_usage;
          Alcotest.test_case "add_usage_no_total" `Quick test_add_usage_no_total;
          Alcotest.test_case "step" `Quick test_step_construction;
          Alcotest.test_case "result" `Quick test_result_construction;
        ] );
      ( "text_stream_part",
        [
          Alcotest.test_case "basic_parts" `Quick test_stream_parts;
          Alcotest.test_case "tool_parts" `Quick test_tool_stream_parts;
        ] );
    ]
