open Alcotest

let system_message_mode_testable =
  let pp fmt = function
    | Ai_provider_openrouter.Model_catalog.System -> Format.fprintf fmt "System"
    | Developer -> Format.fprintf fmt "Developer"
    | Remove -> Format.fprintf fmt "Remove"
  in
  let equal a b =
    match a, b with
    | Ai_provider_openrouter.Model_catalog.System, Ai_provider_openrouter.Model_catalog.System -> true
    | Developer, Developer -> true
    | Remove, Remove -> true
    | (System | Developer | Remove), _ -> false
  in
  testable pp equal

let test_thinking_suffix_developer () =
  (check system_message_mode_testable) "claude thinking" Developer
    (Ai_provider_openrouter.Model_catalog.infer_system_message_mode "anthropic/claude-3.7-sonnet:thinking");
  (check system_message_mode_testable) "deepseek thinking" Developer
    (Ai_provider_openrouter.Model_catalog.infer_system_message_mode "deepseek/deepseek-r1:thinking")

let test_standard_models_system () =
  (check system_message_mode_testable) "gpt-4o" System
    (Ai_provider_openrouter.Model_catalog.infer_system_message_mode "openai/gpt-4o");
  (check system_message_mode_testable) "claude without thinking" System
    (Ai_provider_openrouter.Model_catalog.infer_system_message_mode "anthropic/claude-3.5-sonnet")

let () =
  run "Model_catalog"
    [
      ( "infer_system_message_mode",
        [
          test_case "thinking_suffix" `Quick test_thinking_suffix_developer;
          test_case "standard_models" `Quick test_standard_models_system;
        ] );
    ]
