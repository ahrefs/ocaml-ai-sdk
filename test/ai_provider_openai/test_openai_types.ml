open Alcotest

let test_default_options () =
  let opts = Ai_provider_openai.Openai_options.default in
  (check bool) "strict_json_schema" true opts.strict_json_schema;
  (check (list pass)) "logit_bias" [] opts.logit_bias;
  (check (list pass)) "metadata" [] opts.metadata;
  (check (option pass)) "user" None opts.user

let test_round_trip () =
  let opts = { Ai_provider_openai.Openai_options.default with user = Some "test-user" } in
  let po = Ai_provider_openai.Openai_options.to_provider_options opts in
  let found = Ai_provider_openai.Openai_options.of_provider_options po in
  match found with
  | Some o -> (check (option string)) "user" (Some "test-user") o.user
  | None -> fail "expected Some"

let test_empty_provider_options () =
  let found = Ai_provider_openai.Openai_options.of_provider_options Ai_provider.Provider_options.empty in
  (check (option pass)) "not found" None found

let test_reasoning_effort_strings () =
  let open Ai_provider_openai.Openai_options in
  (check string) "none" "none" (reasoning_effort_to_string Re_none);
  (check string) "minimal" "minimal" (reasoning_effort_to_string Minimal);
  (check string) "low" "low" (reasoning_effort_to_string Low);
  (check string) "medium" "medium" (reasoning_effort_to_string Medium);
  (check string) "high" "high" (reasoning_effort_to_string High);
  (check string) "xhigh" "xhigh" (reasoning_effort_to_string Xhigh)

let test_service_tier_strings () =
  let open Ai_provider_openai.Openai_options in
  (check string) "auto" "auto" (service_tier_to_string St_auto);
  (check string) "flex" "flex" (service_tier_to_string Flex);
  (check string) "priority" "priority" (service_tier_to_string Priority);
  (check string) "default" "default" (service_tier_to_string St_default)

let test_gadt_isolation () =
  (* OpenAI key should not find options stored with a different key *)
  let other_opts = Ai_provider.Provider_options.empty in
  let found = Ai_provider_openai.Openai_options.of_provider_options other_opts in
  (check (option pass)) "not found" None found

let () =
  run "OpenAI_types"
    [
      ( "openai_options",
        [
          test_case "default" `Quick test_default_options;
          test_case "round_trip" `Quick test_round_trip;
          test_case "empty" `Quick test_empty_provider_options;
          test_case "reasoning_effort" `Quick test_reasoning_effort_strings;
          test_case "service_tier" `Quick test_service_tier_strings;
          test_case "gadt_isolation" `Quick test_gadt_isolation;
        ] );
    ]
