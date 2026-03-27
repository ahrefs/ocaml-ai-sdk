open Alcotest

let make_mock_config response =
  let fetch ~url:_ ~headers:_ ~body:_ = Lwt.return response in
  Ai_provider_openai.Config.create ~api_key:"sk-test" ~fetch ()

let test_generate_text () =
  let response =
    `Assoc
      [
        "id", `String "chatcmpl-123";
        "model", `String "gpt-4o";
        ( "choices",
          `List
            [
              `Assoc
                [
                  "index", `Int 0;
                  "message", `Assoc [ "role", `String "assistant"; "content", `String "Hello!" ];
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
      ~prompt:[ User { content = [ Text { text = "Hi"; provider_options = Ai_provider.Provider_options.empty } ] } ]
  in
  let result = Lwt_main.run (M.generate opts) in
  (check int) "content" 1 (List.length result.content);
  match result.content with
  | Text { text } :: _ -> (check string) "text" "Hello!" text
  | _ -> fail "expected Text"

let test_generate_tool_call () =
  let response =
    `Assoc
      [
        ( "choices",
          `List
            [
              `Assoc
                [
                  "index", `Int 0;
                  ( "message",
                    `Assoc
                      [
                        "role", `String "assistant";
                        ( "tool_calls",
                          `List
                            [
                              `Assoc
                                [
                                  "id", `String "call_1";
                                  "type", `String "function";
                                  ( "function",
                                    `Assoc [ "name", `String "get_weather"; "arguments", `String {|{"city":"NYC"}|} ] );
                                ];
                            ] );
                      ] );
                  "finish_reason", `String "tool_calls";
                ];
            ] );
        "usage", `Assoc [ "prompt_tokens", `Int 20; "completion_tokens", `Int 10 ];
      ]
  in
  let config = make_mock_config response in
  let model = Ai_provider_openai.Openai_model.create ~config ~model:"gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [ User { content = [ Text { text = "Weather?"; provider_options = Ai_provider.Provider_options.empty } ] } ])
      with
      tools =
        [ { name = "get_weather"; description = Some "Get weather"; parameters = `Assoc [ "type", `String "object" ] } ];
    }
  in
  let result = Lwt_main.run (M.generate opts) in
  (check int) "content" 1 (List.length result.content);
  match result.content with
  | Tool_call { tool_name; _ } :: _ -> (check string) "name" "get_weather" tool_name
  | _ -> fail "expected Tool_call"

let test_warns_top_k () =
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
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [ User { content = [ Text { text = "test"; provider_options = Ai_provider.Provider_options.empty } ] } ])
      with
      top_k = Some 10;
    }
  in
  let result = Lwt_main.run (M.generate opts) in
  let has_top_k_warning =
    List.exists
      (function
        | Ai_provider.Warning.Unsupported_feature { feature; _ } -> String.equal feature "top_k"
        | _ -> false)
      result.warnings
  in
  (check bool) "has top_k warning" true has_top_k_warning

let test_model_accessors () =
  let config = make_mock_config (`Assoc []) in
  let model = Ai_provider_openai.Openai_model.create ~config ~model:"gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  (check string) "provider" "openai" M.provider;
  (check string) "model_id" "gpt-4o" M.model_id

let () =
  run "Openai_model"
    [
      ( "generate",
        [
          test_case "text" `Quick test_generate_text;
          test_case "tool_call" `Quick test_generate_tool_call;
          test_case "warns_top_k" `Quick test_warns_top_k;
        ] );
      "accessors", [ test_case "model_accessors" `Quick test_model_accessors ];
    ]
