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
      (fun args ->
        let query = try (query_args_of_json args).query with _ -> "unknown" in
        Lwt.return (`String (Printf.sprintf "Results for: %s" query)));
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
  (* Tool not found -> error result, but continues *)
  (check int) "2 steps" 2 (List.length result.steps);
  let tr = List.nth result.tool_results 0 in
  (check bool) "is_error" true tr.is_error

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

let test_generate_without_output () =
  let model = make_text_model "Hello!" in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ()) in
  match result.output with
  | None -> ()
  | Some _ -> fail "expected None when no output spec"

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
      "errors", [ test_case "prompt_and_messages" `Quick test_prompt_and_messages_conflict ];
      ( "output",
        [
          test_case "object_output" `Quick test_generate_with_object_output;
          test_case "enum_output" `Quick test_generate_with_enum_output;
          test_case "invalid_output" `Quick test_generate_with_invalid_output;
          test_case "no_output" `Quick test_generate_without_output;
        ] );
    ]
