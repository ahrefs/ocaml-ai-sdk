open Alcotest

(* Config tests *)

let test_config_default_base_url () =
  let config = Ai_provider_openai.Config.create () in
  (check string) "base_url" "https://api.openai.com/v1" config.base_url

let test_config_custom_api_key () =
  let config = Ai_provider_openai.Config.create ~api_key:"sk-test" () in
  (check (option string)) "api_key" (Some "sk-test") config.api_key

let test_config_api_key_exn_raises () =
  let config = Ai_provider_openai.Config.create () in
  let config = { config with api_key = None } in
  try
    ignore (Ai_provider_openai.Config.api_key_exn config : string);
    fail "expected Failure"
  with Failure _ -> ()

let test_config_custom_base_url () =
  let config = Ai_provider_openai.Config.create ~base_url:"https://custom.api.com/v1" () in
  (check string) "base_url" "https://custom.api.com/v1" config.base_url

let test_config_headers () =
  let config = Ai_provider_openai.Config.create ~headers:[ "x-custom", "value" ] () in
  (check int) "headers count" 1 (List.length config.default_headers)

let test_config_organization () =
  let config = Ai_provider_openai.Config.create ~organization:"org-123" () in
  (check (option string)) "organization" (Some "org-123") config.organization

let test_config_project () =
  let config = Ai_provider_openai.Config.create ~project:"proj-456" () in
  (check (option string)) "project" (Some "proj-456") config.project

(* Model catalog tests *)

let test_model_id_gpt_4o () = (check string) "gpt-4o" "gpt-4o" (Ai_provider_openai.Model_catalog.to_model_id Gpt_4o)

let test_model_id_o3_mini () = (check string) "o3-mini" "o3-mini" (Ai_provider_openai.Model_catalog.to_model_id O3_mini)

let test_of_model_id_exact () =
  let m = Ai_provider_openai.Model_catalog.of_model_id "gpt-4o" in
  match m with
  | Ai_provider_openai.Model_catalog.Gpt_4o -> ()
  | _ -> fail "expected Gpt_4o"

let test_of_model_id_custom () =
  let m = Ai_provider_openai.Model_catalog.of_model_id "gpt-4o-2024-08-06" in
  match m with
  | Ai_provider_openai.Model_catalog.Custom s -> (check string) "custom" "gpt-4o-2024-08-06" s
  | _ -> fail "expected Custom"

let test_capabilities_gpt4o () =
  let caps = Ai_provider_openai.Model_catalog.capabilities "gpt-4o" in
  (check bool) "reasoning" false caps.is_reasoning_model;
  (check bool) "vision" true caps.supports_vision;
  (check int) "max_tokens" 16_384 caps.default_max_tokens

let test_capabilities_o3 () =
  let caps = Ai_provider_openai.Model_catalog.capabilities "o3-mini" in
  (check bool) "reasoning" true caps.is_reasoning_model

let test_capabilities_o1_dated () =
  let caps = Ai_provider_openai.Model_catalog.capabilities "o1-2024-12-17" in
  (check bool) "reasoning" true caps.is_reasoning_model

let test_capabilities_gpt35 () =
  let caps = Ai_provider_openai.Model_catalog.capabilities "gpt-3.5-turbo" in
  (check bool) "vision" false caps.supports_vision;
  (check bool) "structured_output" false caps.supports_structured_output

let test_capabilities_gpt41 () =
  let caps = Ai_provider_openai.Model_catalog.capabilities "gpt-4.1" in
  (check bool) "reasoning" false caps.is_reasoning_model;
  (check int) "max_tokens" 32_768 caps.default_max_tokens

let test_capabilities_gpt41_dated () =
  let caps = Ai_provider_openai.Model_catalog.capabilities "gpt-4.1-2025-04-14" in
  (check int) "max_tokens" 32_768 caps.default_max_tokens

let test_capabilities_gpt4o_dated () =
  let caps = Ai_provider_openai.Model_catalog.capabilities "gpt-4o-2024-08-06" in
  (check int) "max_tokens" 16_384 caps.default_max_tokens

let test_is_reasoning_model () =
  (check bool) "o1" true (Ai_provider_openai.Model_catalog.is_reasoning_model "o1");
  (check bool) "o3-mini" true (Ai_provider_openai.Model_catalog.is_reasoning_model "o3-mini");
  (check bool) "o4-mini" true (Ai_provider_openai.Model_catalog.is_reasoning_model "o4-mini");
  (check bool) "gpt-4o" false (Ai_provider_openai.Model_catalog.is_reasoning_model "gpt-4o");
  (check bool) "gpt-4.1" false (Ai_provider_openai.Model_catalog.is_reasoning_model "gpt-4.1")

let test_system_message_mode () =
  let caps = Ai_provider_openai.Model_catalog.capabilities "o3-mini" in
  (match caps.system_message_mode with
  | Developer -> ()
  | System | Remove -> fail "expected Developer");
  let caps = Ai_provider_openai.Model_catalog.capabilities "gpt-4o" in
  match caps.system_message_mode with
  | System -> ()
  | Developer | Remove -> fail "expected System"

let () =
  run "Config_and_Catalog"
    [
      ( "config",
        [
          test_case "default_base_url" `Quick test_config_default_base_url;
          test_case "custom_api_key" `Quick test_config_custom_api_key;
          test_case "api_key_exn_raises" `Quick test_config_api_key_exn_raises;
          test_case "custom_base_url" `Quick test_config_custom_base_url;
          test_case "headers" `Quick test_config_headers;
          test_case "organization" `Quick test_config_organization;
          test_case "project" `Quick test_config_project;
        ] );
      ( "model_catalog",
        [
          test_case "gpt_4o" `Quick test_model_id_gpt_4o;
          test_case "o3_mini" `Quick test_model_id_o3_mini;
          test_case "of_model_id_exact" `Quick test_of_model_id_exact;
          test_case "of_model_id_custom" `Quick test_of_model_id_custom;
          test_case "capabilities_gpt4o" `Quick test_capabilities_gpt4o;
          test_case "capabilities_o3" `Quick test_capabilities_o3;
          test_case "capabilities_o1_dated" `Quick test_capabilities_o1_dated;
          test_case "capabilities_gpt35" `Quick test_capabilities_gpt35;
          test_case "capabilities_gpt41" `Quick test_capabilities_gpt41;
          test_case "capabilities_gpt41_dated" `Quick test_capabilities_gpt41_dated;
          test_case "capabilities_gpt4o_dated" `Quick test_capabilities_gpt4o_dated;
          test_case "is_reasoning_model" `Quick test_is_reasoning_model;
          test_case "system_message_mode" `Quick test_system_message_mode;
        ] );
    ]
