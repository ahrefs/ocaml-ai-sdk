open Alcotest

(* Config tests *)

let test_config_default_base_url () =
  let config = Ai_provider_anthropic.Config.create () in
  (check string) "base_url" "https://api.anthropic.com/v1" config.base_url

let test_config_custom_api_key () =
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" () in
  (check (option string)) "api_key" (Some "sk-test") config.api_key

let test_config_api_key_exn_raises () =
  let config = Ai_provider_anthropic.Config.create () in
  let config = { config with api_key = None } in
  try
    ignore (Ai_provider_anthropic.Config.api_key_exn config : string);
    fail "expected Failure"
  with Failure _ -> ()

let test_config_custom_base_url () =
  let config = Ai_provider_anthropic.Config.create ~base_url:"https://custom.api.com/v1" () in
  (check string) "base_url" "https://custom.api.com/v1" config.base_url

let test_config_headers () =
  let config = Ai_provider_anthropic.Config.create ~headers:[ "x-custom", "value" ] () in
  (check int) "headers count" 1 (List.length config.default_headers)

(* Model_catalog tests *)

let test_model_id_opus_4_6 () =
  (check string) "opus 4.6" "claude-opus-4-6" (Ai_provider_anthropic.Model_catalog.to_model_id Claude_opus_4_6)

let test_model_id_sonnet_4_6 () =
  (check string) "sonnet 4.6" "claude-sonnet-4-6" (Ai_provider_anthropic.Model_catalog.to_model_id Claude_sonnet_4_6)

let test_of_model_id_exact () =
  let m = Ai_provider_anthropic.Model_catalog.of_model_id "claude-opus-4-6" in
  match m with
  | Ai_provider_anthropic.Model_catalog.Claude_opus_4_6 -> ()
  | _ -> fail "expected Claude_opus_4_6"

let test_excluded_models_are_custom () =
  List.iter
    (fun id ->
      match Ai_provider_anthropic.Model_catalog.of_model_id id with
      | Ai_provider_anthropic.Model_catalog.Custom s -> (check string) "custom" id s
      | _ -> fail "expected Custom")
    [ "claude-haiku-4-5"; "claude-mythos-preview" ]

let test_of_model_id_custom () =
  let m = Ai_provider_anthropic.Model_catalog.of_model_id "some-future-model" in
  match m with
  | Ai_provider_anthropic.Model_catalog.Custom s -> (check string) "custom" "some-future-model" s
  | _ -> fail "expected Custom"

let test_capabilities_opus_4_6 () =
  let caps = Ai_provider_anthropic.Model_catalog.capabilities Claude_opus_4_6 in
  (check bool) "manual thinking" true
    (match caps.thinking with
    | Some { manual = true; _ } -> true
    | _ -> false);
  (check bool) "adaptive thinking" true
    (match caps.thinking with
    | Some { adaptive = true; _ } -> true
    | _ -> false);
  (check int) "max_tokens" 128_000 caps.max_output_tokens

let test_capabilities_custom () =
  let caps = Ai_provider_anthropic.Model_catalog.capabilities (Custom "unknown") in
  (check bool) "thinking" true (Option.is_none caps.thinking);
  (check int) "max_tokens" 4096 caps.max_output_tokens

let test_capability_matrix () =
  let all_effort = [ "low"; "medium"; "high"; "xhigh"; "max" ] in
  let no_xhigh = [ "low"; "medium"; "high"; "max" ] in
  let matrix =
    [
      ( "claude-fable-5",
        128_000,
        512,
        false,
        true,
        true,
        Ai_provider_anthropic.Model_catalog.Unsupported,
        all_effort,
        true,
        true,
        Some "omitted" );
      ( "claude-mythos-5",
        128_000,
        512,
        false,
        true,
        true,
        Ai_provider_anthropic.Model_catalog.Unsupported,
        all_effort,
        true,
        true,
        Some "omitted" );
      ( "claude-opus-5",
        128_000,
        512,
        false,
        true,
        true,
        Ai_provider_anthropic.Model_catalog.Up_to_high,
        all_effort,
        true,
        true,
        Some "omitted" );
      ( "claude-opus-4-8",
        128_000,
        1024,
        false,
        true,
        false,
        Ai_provider_anthropic.Model_catalog.Allowed,
        all_effort,
        true,
        true,
        Some "omitted" );
      ( "claude-sonnet-5",
        128_000,
        1024,
        false,
        true,
        true,
        Ai_provider_anthropic.Model_catalog.Allowed,
        all_effort,
        true,
        true,
        Some "omitted" );
      ( "claude-opus-4-7",
        128_000,
        2048,
        false,
        true,
        false,
        Ai_provider_anthropic.Model_catalog.Allowed,
        all_effort,
        true,
        true,
        Some "omitted" );
      ( "claude-opus-4-6",
        128_000,
        4096,
        true,
        true,
        false,
        Ai_provider_anthropic.Model_catalog.Allowed,
        no_xhigh,
        false,
        true,
        Some "summarized" );
      ( "claude-sonnet-4-6",
        128_000,
        1024,
        true,
        true,
        false,
        Ai_provider_anthropic.Model_catalog.Allowed,
        no_xhigh,
        false,
        true,
        Some "summarized" );
    ]
  in
  List.iter
    (fun ( id,
           max_tokens,
           min_cache_tokens,
           manual,
           adaptive,
           defaults_to_adaptive,
           disabled,
           efforts,
           rejects_sampling,
           structured,
           display_default ) ->
      let caps =
        Ai_provider_anthropic.Model_catalog.capabilities (Ai_provider_anthropic.Model_catalog.of_model_id id)
      in
      let thinking =
        match caps.thinking with
        | Some thinking -> thinking
        | None -> fail ("missing thinking for " ^ id)
      in
      (check int) (id ^ " max_tokens") max_tokens caps.max_output_tokens;
      (check int) (id ^ " min_cache_tokens") min_cache_tokens caps.min_cache_tokens;
      (check bool) (id ^ " manual") manual thinking.manual;
      (check bool) (id ^ " adaptive") adaptive thinking.adaptive;
      (check bool) (id ^ " defaults_to_adaptive") defaults_to_adaptive thinking.defaults_to_adaptive;
      (check bool) (id ^ " rejects_sampling") rejects_sampling caps.rejects_sampling_parameters;
      (check bool) (id ^ " structured_output") structured caps.supports_structured_output;
      (check (list string))
        (id ^ " effort") efforts
        (List.map Ai_provider_anthropic.Effort.to_string thinking.effort_levels);
      (check (option string))
        (id ^ " display_default") display_default
        (Option.map
           (function
             | Ai_provider_anthropic.Thinking.Summarized -> "summarized"
             | Ai_provider_anthropic.Thinking.Omitted -> "omitted")
           thinking.display_default);
      (check bool) (id ^ " disabled") true
        (match disabled, thinking.disabled with
        | Ai_provider_anthropic.Model_catalog.Allowed, Ai_provider_anthropic.Model_catalog.Allowed
        | Ai_provider_anthropic.Model_catalog.Up_to_high, Ai_provider_anthropic.Model_catalog.Up_to_high
        | Ai_provider_anthropic.Model_catalog.Unsupported, Ai_provider_anthropic.Model_catalog.Unsupported ->
          true
        | _ -> false))
    matrix

let test_default_max_tokens () =
  (check int) "opus 4.6" 128_000 (Ai_provider_anthropic.Model_catalog.default_max_tokens Claude_opus_4_6);
  (check int) "sonnet 4.6" 128_000 (Ai_provider_anthropic.Model_catalog.default_max_tokens Claude_sonnet_4_6)

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
        ] );
      ( "model_catalog",
        [
          test_case "opus_4_6" `Quick test_model_id_opus_4_6;
          test_case "sonnet_4_6" `Quick test_model_id_sonnet_4_6;
          test_case "of_model_id_exact" `Quick test_of_model_id_exact;
          test_case "excluded_models_are_custom" `Quick test_excluded_models_are_custom;
          test_case "of_model_id_custom" `Quick test_of_model_id_custom;
          test_case "capabilities_opus_4_6" `Quick test_capabilities_opus_4_6;
          test_case "capabilities_custom" `Quick test_capabilities_custom;
          test_case "capability_matrix" `Quick test_capability_matrix;
          test_case "default_max_tokens" `Quick test_default_max_tokens;
        ] );
    ]
