open Alcotest

let make_mock_config response =
  let fetch ~url:_ ~headers:_ ~body:_ = Lwt.return response in
  Ai_provider_openrouter.Config.create ~api_key:"sk-or-test" ~fetch ()

let test_e2e_generate () =
  let response =
    `Assoc
      [
        "id", `String "gen-e2e";
        "model", `String "openai/gpt-4o";
        ( "choices",
          `List
            [
              `Assoc
                [
                  "index", `Int 0;
                  "message", `Assoc [ "role", `String "assistant"; "content", `String "E2E works!" ];
                  "finish_reason", `String "stop";
                ];
            ] );
        "usage", `Assoc [ "prompt_tokens", `Int 5; "completion_tokens", `Int 3; "total_tokens", `Int 8 ];
      ]
  in
  let config = make_mock_config response in
  let provider =
    let module P = struct
      let name = "openrouter"
      let language_model model_id = Ai_provider_openrouter.Openrouter_model.create ~config ~model:model_id
    end in
    (module P : Ai_provider.Provider.S)
  in
  let model = Ai_provider.Provider.language_model provider "openai/gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  (check string) "provider" "openrouter" M.provider;
  let opts =
    Ai_provider.Call_options.default
      ~prompt:[ User { content = [ Text { text = "test"; provider_options = Ai_provider.Provider_options.empty } ] } ]
  in
  let result = Lwt_main.run (M.generate opts) in
  (check int) "content" 1 (List.length result.content);
  (check string) "finish_reason" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  (check int) "input_tokens" 5 result.usage.input_tokens;
  (check int) "output_tokens" 3 result.usage.output_tokens

let test_e2e_with_provider_options () =
  let response =
    `Assoc
      [
        "id", `String "gen-opts";
        "model", `String "openai/gpt-4o";
        ( "choices",
          `List
            [
              `Assoc
                [
                  "index", `Int 0;
                  "message", `Assoc [ "role", `String "assistant"; "content", `String "OK" ];
                  "finish_reason", `String "stop";
                ];
            ] );
        ( "usage",
          `Assoc
            [
              "prompt_tokens", `Int 10;
              "completion_tokens", `Int 2;
              "prompt_tokens_details", `Assoc [ "cached_tokens", `Int 5 ];
              "completion_tokens_details", `Assoc [ "reasoning_tokens", `Int 1 ];
            ] );
      ]
  in
  let config = make_mock_config response in
  let model = Ai_provider_openrouter.Openrouter_model.create ~config ~model:"openai/gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  let or_opts =
    {
      Ai_provider_openrouter.Openrouter_options.default with
      include_reasoning = Some true;
      plugins = [ Web_search None ];
    }
  in
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [ User { content = [ Text { text = "search"; provider_options = Ai_provider.Provider_options.empty } ] } ])
      with
      provider_options = Ai_provider_openrouter.Openrouter_options.to_provider_options or_opts;
    }
  in
  let result = Lwt_main.run (M.generate opts) in
  (* Check extended usage metadata *)
  let metadata =
    Ai_provider.Provider_options.find Ai_provider_openrouter.Convert_usage.Openrouter_usage result.provider_metadata
  in
  (match metadata with
  | Some m ->
    (check int) "cache_read_tokens" 5 m.cache_read_tokens;
    (check int) "reasoning_tokens" 1 m.reasoning_tokens
  | None -> fail "expected openrouter usage metadata")

let () =
  run "E2E"
    [
      ( "e2e",
        [
          test_case "generate" `Quick test_e2e_generate;
          test_case "with_provider_options" `Quick test_e2e_with_provider_options;
        ] );
    ]
