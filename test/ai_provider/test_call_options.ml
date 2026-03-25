open Alcotest

let test_default_options () =
  let prompt = [ Ai_provider.Prompt.System { content = "You are helpful" } ] in
  let opts = Ai_provider.Call_options.default ~prompt in
  (check int) "no tools" 0 (List.length opts.tools);
  (check bool) "no tool_choice" true (Option.is_none opts.tool_choice);
  (check bool) "no temperature" true (Option.is_none opts.temperature);
  (check bool) "no max_tokens" true (Option.is_none opts.max_output_tokens);
  (check int) "no stop_sequences" 0 (List.length opts.stop_sequences);
  (check int) "no headers" 0 (List.length opts.headers);
  match opts.mode with
  | Ai_provider.Mode.Regular -> ()
  | Ai_provider.Mode.Object_json _ | Ai_provider.Mode.Object_tool _ -> fail "expected Regular mode"

let test_generate_result () =
  let result : Ai_provider.Generate_result.t =
    {
      content = [ Text { text = "hello" } ];
      finish_reason = Stop;
      usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
      warnings = [];
      provider_metadata = Ai_provider.Provider_options.empty;
      request = { body = `Null };
      response = { id = Some "r1"; model = Some "test"; headers = []; body = `Null };
    }
  in
  (check int) "content count" 1 (List.length result.content);
  (check string) "finish" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason)

let test_stream_parts () =
  let parts : Ai_provider.Stream_part.t list =
    [
      Stream_start { warnings = [] };
      Text { text = "hello " };
      Text { text = "world" };
      Finish { finish_reason = Stop; usage = { input_tokens = 10; output_tokens = 5; total_tokens = None } };
    ]
  in
  (check int) "4 parts" 4 (List.length parts)

let test_stream_result () =
  let stream, push = Lwt_stream.create () in
  push (Some (Ai_provider.Stream_part.Text { text = "hi" }));
  push None;
  let result : Ai_provider.Stream_result.t = { stream; warnings = []; raw_response = None } in
  let parts = Lwt_main.run (Lwt_stream.to_list result.stream) in
  (check int) "1 part" 1 (List.length parts)

let () =
  run "Call_options_and_results"
    [
      "call_options", [ test_case "default" `Quick test_default_options ];
      "generate_result", [ test_case "construction" `Quick test_generate_result ];
      "stream_part", [ test_case "variants" `Quick test_stream_parts ];
      "stream_result", [ test_case "with_stream" `Quick test_stream_result ];
    ]
