open Alcotest

let test_language_model () =
  let model = Ai_provider_openai.language_model ~api_key:"sk-test" ~model:"gpt-4o" () in
  let module M = (val model : Ai_provider.Language_model.S) in
  (check string) "provider" "openai" M.provider;
  (check string) "model_id" "gpt-4o" M.model_id

let test_create_provider () =
  let provider = Ai_provider_openai.create ~api_key:"sk-test" () in
  let module P = (val provider : Ai_provider.Provider.S) in
  (check string) "name" "openai" P.name;
  let model = P.language_model "gpt-4o-mini" in
  let module M = (val model : Ai_provider.Language_model.S) in
  (check string) "model_id" "gpt-4o-mini" M.model_id

let test_model_shortcut () =
  (* This will use env var; just test it doesn't crash even without key *)
  let model = Ai_provider_openai.model "gpt-4o" in
  let module M = (val model : Ai_provider.Language_model.S) in
  (check string) "model_id" "gpt-4o" M.model_id;
  (check string) "provider" "openai" M.provider

let () =
  run "Factory"
    [
      ( "factory",
        [
          test_case "language_model" `Quick test_language_model;
          test_case "create_provider" `Quick test_create_provider;
          test_case "model_shortcut" `Quick test_model_shortcut;
        ] );
    ]
