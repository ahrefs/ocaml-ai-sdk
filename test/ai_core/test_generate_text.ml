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
      (fun args ->
        let query = try Yojson.Safe.Util.(member "query" args |> to_string) with _ -> "unknown" in
        Lwt.return (`String (Printf.sprintf "Results for: %s" query)));
  }

(* Tests *)

let test_simple_text () =
  let model = make_text_model "Hello world!" in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Say hello" ()) in
  Alcotest.(check string) "text" "Hello world!" result.text;
  Alcotest.(check string) "finish" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  Alcotest.(check int) "1 step" 1 (List.length result.steps);
  Alcotest.(check int) "no tool calls" 0 (List.length result.tool_calls)

let test_with_system () =
  let model = make_text_model "I am helpful." in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~system:"Be helpful" ~prompt:"Hello" ()) in
  Alcotest.(check string) "text" "I am helpful." result.text

let test_tool_loop () =
  let model = make_tool_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Search for test"
         ~tools:[ "search", search_tool ]
         ~max_steps:3 ())
  in
  (* Should have 2 steps: tool call + final answer *)
  Alcotest.(check int) "2 steps" 2 (List.length result.steps);
  Alcotest.(check string) "final text" "Let me search.\nFound the answer!" result.text;
  Alcotest.(check int) "1 tool call" 1 (List.length result.tool_calls);
  Alcotest.(check int) "1 tool result" 1 (List.length result.tool_results);
  (* Usage should be aggregated *)
  Alcotest.(check int) "total input" 30 result.usage.input_tokens;
  Alcotest.(check int) "total output" 25 result.usage.output_tokens

let test_tool_not_found () =
  let model = make_tool_model () in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Test" ~tools:[] ~max_steps:3 ()) in
  (* Tool not found -> error result, but continues *)
  Alcotest.(check int) "2 steps" 2 (List.length result.steps);
  let tr = List.nth result.tool_results 0 in
  Alcotest.(check bool) "is_error" true tr.is_error

let test_max_steps_1 () =
  let model = make_tool_model () in
  let result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Test" ~tools:[ "search", search_tool ] ~max_steps:1 ())
  in
  (* max_steps=1 means only 1 call, tool call returned but not executed *)
  Alcotest.(check int) "1 step" 1 (List.length result.steps);
  Alcotest.(check int) "1 tool call" 1 (List.length result.tool_calls);
  Alcotest.(check int) "0 tool results" 0 (List.length result.tool_results)

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
  Alcotest.(check int) "2 callbacks" 2 !step_count

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
  Alcotest.(check bool) "raises" true !raised

let () =
  Alcotest.run "Generate_text"
    [
      ( "basic",
        [
          Alcotest.test_case "simple_text" `Quick test_simple_text;
          Alcotest.test_case "with_system" `Quick test_with_system;
        ] );
      ( "tools",
        [
          Alcotest.test_case "tool_loop" `Quick test_tool_loop;
          Alcotest.test_case "tool_not_found" `Quick test_tool_not_found;
          Alcotest.test_case "max_steps_1" `Quick test_max_steps_1;
          Alcotest.test_case "on_step_finish" `Quick test_on_step_finish;
        ] );
      "errors", [ Alcotest.test_case "prompt_and_messages" `Quick test_prompt_and_messages_conflict ];
    ]
