(* Config tests *)

let test_config_default_base_url () =
  let config = Ai_provider_anthropic.Config.create () in
  Alcotest.(check string) "base_url" "https://api.anthropic.com/v1" config.base_url

let test_config_custom_api_key () =
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" () in
  Alcotest.(check (option string)) "api_key" (Some "sk-test") config.api_key

let test_config_api_key_exn_raises () =
  let config = Ai_provider_anthropic.Config.create () in
  let config = { config with api_key = None } in
  try
    ignore (Ai_provider_anthropic.Config.api_key_exn config : string);
    Alcotest.fail "expected Failure"
  with Failure _ -> ()

let test_config_custom_base_url () =
  let config = Ai_provider_anthropic.Config.create ~base_url:"https://custom.api.com/v1" () in
  Alcotest.(check string) "base_url" "https://custom.api.com/v1" config.base_url

let test_config_headers () =
  let config = Ai_provider_anthropic.Config.create ~headers:[ "x-custom", "value" ] () in
  Alcotest.(check int) "headers count" 1 (List.length config.default_headers)

(* Model_catalog tests *)

let test_model_id_opus_4_6 () =
  Alcotest.(check string) "opus 4.6" "claude-opus-4-6" (Ai_provider_anthropic.Model_catalog.to_model_id Claude_opus_4_6)

let test_model_id_sonnet_4_6 () =
  Alcotest.(check string)
    "sonnet 4.6" "claude-sonnet-4-6"
    (Ai_provider_anthropic.Model_catalog.to_model_id Claude_sonnet_4_6)

let test_model_id_haiku_4_5 () =
  Alcotest.(check string)
    "haiku 4.5" "claude-haiku-4-5-20251001"
    (Ai_provider_anthropic.Model_catalog.to_model_id Claude_haiku_4_5)

let test_of_model_id_exact () =
  let m = Ai_provider_anthropic.Model_catalog.of_model_id "claude-opus-4-6" in
  match m with
  | Ai_provider_anthropic.Model_catalog.Claude_opus_4_6 -> ()
  | _ -> Alcotest.fail "expected Claude_opus_4_6"

let test_of_model_id_alias () =
  let m = Ai_provider_anthropic.Model_catalog.of_model_id "claude-haiku-4-5" in
  match m with
  | Ai_provider_anthropic.Model_catalog.Claude_haiku_4_5 -> ()
  | _ -> Alcotest.fail "expected Claude_haiku_4_5"

let test_of_model_id_custom () =
  let m = Ai_provider_anthropic.Model_catalog.of_model_id "some-future-model" in
  match m with
  | Ai_provider_anthropic.Model_catalog.Custom s -> Alcotest.(check string) "custom" "some-future-model" s
  | _ -> Alcotest.fail "expected Custom"

let test_capabilities_opus_4_6 () =
  let caps = Ai_provider_anthropic.Model_catalog.capabilities Claude_opus_4_6 in
  Alcotest.(check bool) "thinking" true caps.supports_thinking;
  Alcotest.(check int) "max_tokens" 128_000 caps.max_output_tokens

let test_capabilities_haiku_4_5 () =
  let caps = Ai_provider_anthropic.Model_catalog.capabilities Claude_haiku_4_5 in
  Alcotest.(check int) "max_tokens" 64_000 caps.max_output_tokens;
  Alcotest.(check int) "min_cache" 4096 caps.min_cache_tokens

let test_capabilities_custom () =
  let caps = Ai_provider_anthropic.Model_catalog.capabilities (Custom "unknown") in
  Alcotest.(check bool) "thinking" false caps.supports_thinking;
  Alcotest.(check int) "max_tokens" 4096 caps.max_output_tokens

let test_default_max_tokens () =
  Alcotest.(check int) "opus 4.6" 128_000 (Ai_provider_anthropic.Model_catalog.default_max_tokens Claude_opus_4_6);
  Alcotest.(check int) "sonnet 4.6" 64_000 (Ai_provider_anthropic.Model_catalog.default_max_tokens Claude_sonnet_4_6)

let () =
  Alcotest.run "Config_and_Catalog"
    [
      ( "config",
        [
          Alcotest.test_case "default_base_url" `Quick test_config_default_base_url;
          Alcotest.test_case "custom_api_key" `Quick test_config_custom_api_key;
          Alcotest.test_case "api_key_exn_raises" `Quick test_config_api_key_exn_raises;
          Alcotest.test_case "custom_base_url" `Quick test_config_custom_base_url;
          Alcotest.test_case "headers" `Quick test_config_headers;
        ] );
      ( "model_catalog",
        [
          Alcotest.test_case "opus_4_6" `Quick test_model_id_opus_4_6;
          Alcotest.test_case "sonnet_4_6" `Quick test_model_id_sonnet_4_6;
          Alcotest.test_case "haiku_4_5" `Quick test_model_id_haiku_4_5;
          Alcotest.test_case "of_model_id_exact" `Quick test_of_model_id_exact;
          Alcotest.test_case "of_model_id_alias" `Quick test_of_model_id_alias;
          Alcotest.test_case "of_model_id_custom" `Quick test_of_model_id_custom;
          Alcotest.test_case "capabilities_opus_4_6" `Quick test_capabilities_opus_4_6;
          Alcotest.test_case "capabilities_haiku_4_5" `Quick test_capabilities_haiku_4_5;
          Alcotest.test_case "capabilities_custom" `Quick test_capabilities_custom;
          Alcotest.test_case "default_max_tokens" `Quick test_default_max_tokens;
        ] );
    ]
