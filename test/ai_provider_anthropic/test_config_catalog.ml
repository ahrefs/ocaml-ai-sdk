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

let test_model_id_opus_4_8 () =
  (check string) "opus 4.8" "claude-opus-4-8" (Ai_provider_anthropic.Model_catalog.to_model_id Claude_opus_4_8)

let test_model_id_haiku_4_5 () =
  (check string) "haiku 4.5" "claude-haiku-4-5-20251001"
    (Ai_provider_anthropic.Model_catalog.to_model_id Claude_haiku_4_5)

let test_of_model_id_exact () =
  let m = Ai_provider_anthropic.Model_catalog.of_model_id "claude-opus-4-8" in
  match m with
  | Ai_provider_anthropic.Model_catalog.Claude_opus_4_8 -> ()
  | _ -> fail "expected Claude_opus_4_8"

(* Both the dated and undated Haiku 4.5 ids resolve to the known constructor. *)
let test_of_model_id_haiku_aliases () =
  List.iter
    (fun id ->
      match Ai_provider_anthropic.Model_catalog.of_model_id id with
      | Ai_provider_anthropic.Model_catalog.Claude_haiku_4_5 -> ()
      | _ -> fail "expected Claude_haiku_4_5")
    [ "claude-haiku-4-5"; "claude-haiku-4-5-20251001" ]

let test_excluded_models_are_custom () =
  List.iter
    (fun id ->
      match Ai_provider_anthropic.Model_catalog.of_model_id id with
      | Ai_provider_anthropic.Model_catalog.Custom s -> (check string) "custom" id s
      | _ -> fail "expected Custom")
    [ "claude-sonnet-4-6"; "claude-mythos-preview" ]

let test_of_model_id_custom () =
  let m = Ai_provider_anthropic.Model_catalog.of_model_id "some-future-model" in
  match m with
  | Ai_provider_anthropic.Model_catalog.Custom s -> (check string) "custom" "some-future-model" s
  | _ -> fail "expected Custom"

let test_capabilities_haiku_4_5 () =
  let caps = Ai_provider_anthropic.Model_catalog.capabilities Claude_haiku_4_5 in
  (check bool) "manual thinking" true
    (match caps.thinking with
    | Some { manual = true; _ } -> true
    | _ -> false);
  (* Haiku 4.5 predates adaptive thinking and exposes no effort levels. *)
  (check bool) "not adaptive" true
    (match caps.thinking with
    | Some { adaptive = false; _ } -> true
    | _ -> false);
  (check bool) "no effort levels" true
    (match caps.thinking with
    | Some { effort_levels = []; _ } -> true
    | _ -> false);
  (check int) "max_tokens" 64_000 caps.max_output_tokens

let test_capabilities_custom () =
  let caps = Ai_provider_anthropic.Model_catalog.capabilities (Custom "unknown") in
  (check bool) "thinking" true (Option.is_none caps.thinking);
  (check int) "max_tokens" 4096 caps.max_output_tokens

type expected_capabilities = {
  id : string;
  max_tokens : int;
  min_cache_tokens : int;
  manual : bool;
  adaptive : bool;
  defaults_to_adaptive : bool;
  disabled : Ai_provider_anthropic.Model_catalog.disabled_thinking_support;
  efforts : string list;
  display_default : string option;
  between_tools : bool;
  rejects_sampling : bool;
  structured : bool;
  prompt_caching : bool;
  vision : bool;
  pdf : bool;
  rejects_forced_tool_choice : bool;
}

let test_capability_matrix () =
  (* The adaptive generation's common values; each row states how it differs. *)
  let adaptive =
    {
      id = "";
      max_tokens = 128_000;
      min_cache_tokens = 512;
      manual = false;
      adaptive = true;
      defaults_to_adaptive = true;
      disabled = Ai_provider_anthropic.Model_catalog.Unsupported;
      efforts = [ "low"; "medium"; "high"; "xhigh"; "max" ];
      display_default = Some "omitted";
      between_tools = false;
      rejects_sampling = true;
      structured = true;
      prompt_caching = true;
      vision = true;
      pdf = true;
      rejects_forced_tool_choice = false;
    }
  in
  let matrix =
    [
      { adaptive with id = "claude-fable-5-1"; rejects_forced_tool_choice = true };
      { adaptive with id = "claude-fable-5" };
      { adaptive with id = "claude-mythos-5-1"; rejects_forced_tool_choice = true };
      { adaptive with id = "claude-mythos-5" };
      { adaptive with id = "claude-opus-5-5"; rejects_forced_tool_choice = true };
      { adaptive with id = "claude-opus-5"; disabled = Ai_provider_anthropic.Model_catalog.Up_to_high };
      {
        adaptive with
        id = "claude-opus-4-8";
        min_cache_tokens = 1024;
        defaults_to_adaptive = false;
        disabled = Ai_provider_anthropic.Model_catalog.Allowed;
      };
      { adaptive with id = "claude-sonnet-5-5"; between_tools = true; rejects_forced_tool_choice = true };
      {
        adaptive with
        id = "claude-sonnet-5";
        min_cache_tokens = 1024;
        disabled = Ai_provider_anthropic.Model_catalog.Allowed;
      };
      { adaptive with id = "claude-haiku-5-5"; disabled = Ai_provider_anthropic.Model_catalog.Up_to_high };
      {
        id = "claude-haiku-4-5";
        max_tokens = 64_000;
        min_cache_tokens = 4096;
        manual = true;
        adaptive = false;
        defaults_to_adaptive = false;
        disabled = Ai_provider_anthropic.Model_catalog.Allowed;
        efforts = [];
        display_default = Some "summarized";
        between_tools = false;
        rejects_sampling = false;
        structured = true;
        prompt_caching = true;
        vision = true;
        pdf = true;
        rejects_forced_tool_choice = false;
      };
    ]
  in
  List.iter
    (fun expected ->
      let id = expected.id in
      let caps =
        Ai_provider_anthropic.Model_catalog.capabilities (Ai_provider_anthropic.Model_catalog.of_model_id id)
      in
      let thinking =
        match caps.thinking with
        | Some thinking -> thinking
        | None -> fail ("missing thinking for " ^ id)
      in
      (check int) (id ^ " max_tokens") expected.max_tokens caps.max_output_tokens;
      (check int) (id ^ " min_cache_tokens") expected.min_cache_tokens caps.min_cache_tokens;
      (check bool) (id ^ " manual") expected.manual thinking.manual;
      (check bool) (id ^ " adaptive") expected.adaptive thinking.adaptive;
      (check bool) (id ^ " defaults_to_adaptive") expected.defaults_to_adaptive thinking.defaults_to_adaptive;
      (check bool) (id ^ " between_tools") expected.between_tools thinking.between_tools;
      (check bool) (id ^ " rejects_sampling") expected.rejects_sampling caps.rejects_sampling_parameters;
      (check bool) (id ^ " structured_output") expected.structured caps.supports_structured_output;
      (check bool) (id ^ " prompt_caching") expected.prompt_caching caps.supports_prompt_caching;
      (check bool) (id ^ " vision") expected.vision caps.supports_vision;
      (check bool) (id ^ " pdf") expected.pdf caps.supports_pdf;
      (check bool) (id ^ " rejects_forced_tool_choice") expected.rejects_forced_tool_choice
        caps.rejects_forced_tool_choice;
      (check (list string))
        (id ^ " effort") expected.efforts
        (List.map Ai_provider_anthropic.Effort.to_string thinking.effort_levels);
      (check (option string))
        (id ^ " display_default") expected.display_default
        (Option.map
           (function
             | Ai_provider_anthropic.Thinking.Summarized -> "summarized"
             | Ai_provider_anthropic.Thinking.Omitted -> "omitted")
           thinking.display_default);
      (check bool) (id ^ " disabled") true
        (match expected.disabled, thinking.disabled with
        | Ai_provider_anthropic.Model_catalog.Allowed, Ai_provider_anthropic.Model_catalog.Allowed
        | Ai_provider_anthropic.Model_catalog.Up_to_high, Ai_provider_anthropic.Model_catalog.Up_to_high
        | Ai_provider_anthropic.Model_catalog.Unsupported, Ai_provider_anthropic.Model_catalog.Unsupported ->
          true
        | _ -> false))
    matrix

let test_default_max_tokens () =
  (check int) "opus 4.8" 128_000 (Ai_provider_anthropic.Model_catalog.default_max_tokens Claude_opus_4_8);
  (check int) "haiku 4.5" 64_000 (Ai_provider_anthropic.Model_catalog.default_max_tokens Claude_haiku_4_5)

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
          test_case "opus_4_8" `Quick test_model_id_opus_4_8;
          test_case "haiku_4_5" `Quick test_model_id_haiku_4_5;
          test_case "of_model_id_exact" `Quick test_of_model_id_exact;
          test_case "of_model_id_haiku_aliases" `Quick test_of_model_id_haiku_aliases;
          test_case "excluded_models_are_custom" `Quick test_excluded_models_are_custom;
          test_case "of_model_id_custom" `Quick test_of_model_id_custom;
          test_case "capabilities_haiku_4_5" `Quick test_capabilities_haiku_4_5;
          test_case "capabilities_custom" `Quick test_capabilities_custom;
          test_case "capability_matrix" `Quick test_capability_matrix;
          test_case "default_max_tokens" `Quick test_default_max_tokens;
        ] );
    ]
