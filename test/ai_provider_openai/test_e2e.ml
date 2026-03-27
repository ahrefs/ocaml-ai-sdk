open Alcotest

(* End-to-end tests using mock fetch *)

let make_mock_config response =
  let fetch ~url:_ ~headers:_ ~body:_ = Lwt.return response in
  Ai_provider_openai.Config.create ~api_key:"sk-test" ~fetch ()

let test_text_through_abstraction () =
  let response =
    `Assoc
      [
        ( "choices",
          `List
            [
              `Assoc
                [
                  "index", `Int 0;
                  "message", `Assoc [ "role", `String "assistant"; "content", `String "Generated text" ];
                  "finish_reason", `String "stop";
                ];
            ] );
        "usage", `Assoc [ "prompt_tokens", `Int 10; "completion_tokens", `Int 5 ];
      ]
  in
  let config = make_mock_config response in
  let model = Ai_provider_openai.Openai_model.create ~config ~model:"gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  let opts =
    Ai_provider.Call_options.default
      ~prompt:[ User { content = [ Text { text = "Hello"; provider_options = Ai_provider.Provider_options.empty } ] } ]
  in
  let result = Lwt_main.run (M.generate opts) in
  (check int) "content" 1 (List.length result.content);
  (match result.finish_reason with
  | Stop -> ()
  | _ -> fail "expected Stop");
  (check int) "input_tokens" 10 result.usage.input_tokens;
  (check int) "output_tokens" 5 result.usage.output_tokens

let test_object_json_mode () =
  let response =
    `Assoc
      [
        ( "choices",
          `List
            [
              `Assoc
                [
                  "index", `Int 0;
                  "message", `Assoc [ "role", `String "assistant"; "content", `String {|{"name":"Alice","age":30}|} ];
                  "finish_reason", `String "stop";
                ];
            ] );
        "usage", `Assoc [ "prompt_tokens", `Int 15; "completion_tokens", `Int 8 ];
      ]
  in
  let config = make_mock_config response in
  let model = Ai_provider_openai.Openai_model.create ~config ~model:"gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [
             User
               {
                 content = [ Text { text = "Give me a person"; provider_options = Ai_provider.Provider_options.empty } ];
               };
           ])
      with
      mode = Object_json (Some { name = "person"; schema = `Assoc [ "type", `String "object" ] });
    }
  in
  let result = Lwt_main.run (M.generate opts) in
  (check int) "content" 1 (List.length result.content);
  match result.content with
  | Text { text } :: _ -> (check bool) "has json" true (String.starts_with ~prefix:"{" text)
  | _ -> fail "expected Text"

let test_provider_options_flow () =
  let response =
    `Assoc
      [
        ( "choices",
          `List
            [
              `Assoc
                [
                  "index", `Int 0;
                  "message", `Assoc [ "role", `String "assistant"; "content", `String "ok" ];
                  "finish_reason", `String "stop";
                ];
            ] );
        "usage", `Assoc [ "prompt_tokens", `Int 1; "completion_tokens", `Int 1 ];
      ]
  in
  let config = make_mock_config response in
  let model = Ai_provider_openai.Openai_model.create ~config ~model:"gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  let openai_opts = { Ai_provider_openai.Openai_options.default with user = Some "test-user"; store = Some true } in
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [ User { content = [ Text { text = "test"; provider_options = Ai_provider.Provider_options.empty } ] } ])
      with
      provider_options = Ai_provider_openai.Openai_options.to_provider_options openai_opts;
    }
  in
  let result = Lwt_main.run (M.generate opts) in
  (check int) "content" 1 (List.length result.content)

let () =
  run "E2E OpenAI"
    [
      ( "generate",
        [
          test_case "text_through_abstraction" `Quick test_text_through_abstraction;
          test_case "object_json_mode" `Quick test_object_json_mode;
          test_case "provider_options_flow" `Quick test_provider_options_flow;
        ] );
    ]
