open Alcotest

let test_language_model () =
  let model = Ai_provider_openrouter.language_model ~api_key:"sk-or-test" ~model:"openai/gpt-4o" () in
  let module M = (val model : Ai_provider.Language_model.S) in
  (check string) "provider" "openrouter" M.provider;
  (check string) "model_id" "openai/gpt-4o" M.model_id

let test_create_provider () =
  let provider = Ai_provider_openrouter.create ~api_key:"sk-or-test" () in
  let module P = (val provider : Ai_provider.Provider.S) in
  (check string) "name" "openrouter" P.name;
  let model = P.language_model "anthropic/claude-3.5-sonnet" in
  let module M = (val model : Ai_provider.Language_model.S) in
  (check string) "model_id" "anthropic/claude-3.5-sonnet" M.model_id

let test_model_shortcut () =
  let model = Ai_provider_openrouter.model "openai/gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  (check string) "model_id" "openai/gpt-4o" M.model_id;
  (check string) "provider" "openrouter" M.provider

let test_app_title_and_url () =
  let _model =
    Ai_provider_openrouter.language_model ~api_key:"sk-or-test" ~app_title:"My App" ~app_url:"https://myapp.com"
      ~model:"openai/gpt-4o" ()
  in
  (* Just check it doesn't crash *)
  ()

let () =
  run "Factory"
    [
      ( "factory",
        [
          test_case "language_model" `Quick test_language_model;
          test_case "create_provider" `Quick test_create_provider;
          test_case "model_shortcut" `Quick test_model_shortcut;
          test_case "app_title_and_url" `Quick test_app_title_and_url;
        ] );
    ]
