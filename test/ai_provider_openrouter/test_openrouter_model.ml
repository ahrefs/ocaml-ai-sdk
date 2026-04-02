open Alcotest

let make_mock_config ?(check_body = fun _ -> ()) response =
  let fetch ~url:_ ~headers:_ ~body =
    check_body body;
    Lwt.return response
  in
  Ai_provider_openrouter.Config.create ~api_key:"sk-or-test" ~fetch ()

let basic_response =
  `Assoc
    [
      "id", `String "gen-123";
      "model", `String "openai/gpt-4o";
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

let test_generate_text () =
  let config = make_mock_config basic_response in
  let model = Ai_provider_openrouter.Openrouter_model.create ~config ~model:"openai/gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  let opts =
    Ai_provider.Call_options.default
      ~prompt:[ User { content = [ Text { text = "Hi"; provider_options = Ai_provider.Provider_options.empty } ] } ]
  in
  let result = Lwt_main.run (M.generate opts) in
  (check int) "content" 1 (List.length result.content);
  (match result.content with
  | Text { text } :: _ -> (check string) "text" "Hello!" text
  | _ -> fail "expected Text")

let test_provider_and_model_id () =
  let config = make_mock_config basic_response in
  let model = Ai_provider_openrouter.Openrouter_model.create ~config ~model:"anthropic/claude-3.5-sonnet" in
  let module M = (val model : Ai_provider.Language_model.S) in
  (check string) "provider" "openrouter" M.provider;
  (check string) "model_id" "anthropic/claude-3.5-sonnet" M.model_id

let test_generate_with_reasoning () =
  let response =
    `Assoc
      [
        "id", `String "gen-456";
        "model", `String "anthropic/claude-3.5-sonnet";
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
                        "content", `String "42";
                        "reasoning", `String "Let me think...";
                      ] );
                  "finish_reason", `String "stop";
                ];
            ] );
        "usage", `Assoc [ "prompt_tokens", `Int 20; "completion_tokens", `Int 30 ];
      ]
  in
  let config = make_mock_config response in
  let model = Ai_provider_openrouter.Openrouter_model.create ~config ~model:"anthropic/claude-3.5-sonnet" in
  let module M = (val model : Ai_provider.Language_model.S) in
  let opts =
    Ai_provider.Call_options.default
      ~prompt:[ User { content = [ Text { text = "What is 6*7?"; provider_options = Ai_provider.Provider_options.empty } ] } ]
  in
  let result = Lwt_main.run (M.generate opts) in
  (match result.content with
  | [ Reasoning { text = r; _ }; Text { text = t } ] ->
    (check string) "reasoning" "Let me think..." r;
    (check string) "text" "42" t
  | _ -> fail "expected [Reasoning; Text] content")

let test_openrouter_options_in_request () =
  let check_body body =
    let json = Yojson.Basic.from_string body in
    (* Check that OpenRouter-specific fields are present *)
    (match json with
    | `Assoc fields ->
      (match List.assoc_opt "plugins" fields with
      | Some (`List plugins) -> (check int) "plugins count" 1 (List.length plugins)
      | _ -> fail "expected plugins in request body");
      (match List.assoc_opt "route" fields with
      | Some (`String route) -> (check string) "route" "fastest" route
      | _ -> fail "expected route in request body");
      (match List.assoc_opt "include_reasoning" fields with
      | Some (`Bool v) -> (check bool) "include_reasoning" true v
      | _ -> fail "expected include_reasoning in request body")
    | _ -> fail "expected JSON object")
  in
  let config = make_mock_config ~check_body basic_response in
  let model = Ai_provider_openrouter.Openrouter_model.create ~config ~model:"openai/gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  let or_opts =
    {
      Ai_provider_openrouter.Openrouter_options.default with
      plugins = [ Auto_router ];
      route = Some Fastest;
      include_reasoning = true;
    }
  in
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [ User { content = [ Text { text = "Hi"; provider_options = Ai_provider.Provider_options.empty } ] } ])
      with
      provider_options = Ai_provider_openrouter.Openrouter_options.to_provider_options or_opts;
    }
  in
  let _result = Lwt_main.run (M.generate opts) in
  ()

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
  let model = Ai_provider_openrouter.Openrouter_model.create ~config ~model:"openai/gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [ User { content = [ Text { text = "Weather?"; provider_options = Ai_provider.Provider_options.empty } ] } ])
      with
      tools = [ { name = "get_weather"; description = Some "Get weather"; parameters = `Assoc [] } ];
    }
  in
  let result = Lwt_main.run (M.generate opts) in
  (match result.content with
  | Tool_call { tool_name; tool_call_id; args; _ } :: _ ->
    (check string) "tool_name" "get_weather" tool_name;
    (check string) "tool_call_id" "call_1" tool_call_id;
    (check string) "args" {|{"city":"NYC"}|} args
  | _ -> fail "expected Tool_call")

let () =
  run "Openrouter_model"
    [
      ( "model",
        [
          test_case "generate_text" `Quick test_generate_text;
          test_case "provider_and_model_id" `Quick test_provider_and_model_id;
          test_case "generate_with_reasoning" `Quick test_generate_with_reasoning;
          test_case "openrouter_options_in_request" `Quick test_openrouter_options_in_request;
          test_case "generate_tool_call" `Quick test_generate_tool_call;
        ] );
    ]
