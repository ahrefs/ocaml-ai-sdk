(* Thinking tests *)

let test_budget_valid () =
  match Ai_provider_anthropic.Thinking.budget 1024 with
  | Ok b -> Alcotest.(check int) "budget" 1024 (Ai_provider_anthropic.Thinking.to_int b)
  | Error _ -> Alcotest.fail "expected Ok"

let test_budget_large () =
  match Ai_provider_anthropic.Thinking.budget 50000 with
  | Ok b -> Alcotest.(check int) "budget" 50000 (Ai_provider_anthropic.Thinking.to_int b)
  | Error _ -> Alcotest.fail "expected Ok"

let test_budget_too_small () =
  match Ai_provider_anthropic.Thinking.budget 1023 with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error msg -> Alcotest.(check bool) "error message" true (String.length msg > 0)

let test_budget_zero () =
  match Ai_provider_anthropic.Thinking.budget 0 with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error _ -> ()

let test_budget_exn_raises () =
  Alcotest.check_raises "raises Invalid_argument" (Invalid_argument "thinking budget must be >= 1024, got 512")
    (fun () -> ignore (Ai_provider_anthropic.Thinking.budget_exn 512 : Ai_provider_anthropic.Thinking.budget_tokens))

(* Cache_control tests *)

let test_ephemeral () =
  let cc = Ai_provider_anthropic.Cache_control.ephemeral in
  match cc.cache_type with
  | Ai_provider_anthropic.Cache_control.Ephemeral -> ()

(* Anthropic_options tests *)

let test_default_options () =
  let opts = Ai_provider_anthropic.Anthropic_options.default in
  Alcotest.(check bool) "no thinking" true (Option.is_none opts.thinking);
  Alcotest.(check bool) "no cache" true (Option.is_none opts.cache_control);
  Alcotest.(check bool) "tool streaming" true opts.tool_streaming;
  match opts.structured_output_mode with
  | Ai_provider_anthropic.Anthropic_options.Auto -> ()
  | Ai_provider_anthropic.Anthropic_options.Output_format | Ai_provider_anthropic.Anthropic_options.Json_tool ->
    Alcotest.fail "expected Auto"

let test_provider_options_round_trip () =
  let opts = Ai_provider_anthropic.Anthropic_options.default in
  let po = Ai_provider_anthropic.Anthropic_options.to_provider_options opts in
  let extracted = Ai_provider_anthropic.Anthropic_options.of_provider_options po in
  Alcotest.(check bool) "round trips" true (Option.is_some extracted)

let test_provider_options_empty () =
  let po = Ai_provider.Provider_options.empty in
  let extracted = Ai_provider_anthropic.Anthropic_options.of_provider_options po in
  Alcotest.(check bool) "empty -> None" true (Option.is_none extracted)

(* Cache_control_options tests *)

let test_cache_control_round_trip () =
  let cc = Ai_provider_anthropic.Cache_control.ephemeral in
  let po =
    Ai_provider_anthropic.Cache_control_options.with_cache_control ~cache_control:cc Ai_provider.Provider_options.empty
  in
  let extracted = Ai_provider_anthropic.Cache_control_options.get_cache_control po in
  Alcotest.(check bool) "found" true (Option.is_some extracted)

let test_cache_control_none () =
  let po = Ai_provider_anthropic.Cache_control_options.with_cache_control Ai_provider.Provider_options.empty in
  let extracted = Ai_provider_anthropic.Cache_control_options.get_cache_control po in
  Alcotest.(check bool) "none" true (Option.is_none extracted)

let test_gadt_isolation () =
  (* Anthropic_options key should not find Cache_control_options and vice versa *)
  let cc = Ai_provider_anthropic.Cache_control.ephemeral in
  let po =
    Ai_provider_anthropic.Cache_control_options.with_cache_control ~cache_control:cc Ai_provider.Provider_options.empty
  in
  let extracted = Ai_provider_anthropic.Anthropic_options.of_provider_options po in
  Alcotest.(check bool) "isolated" true (Option.is_none extracted)

let () =
  Alcotest.run "Anthropic_types"
    [
      ( "thinking",
        [
          Alcotest.test_case "valid_budget" `Quick test_budget_valid;
          Alcotest.test_case "large_budget" `Quick test_budget_large;
          Alcotest.test_case "too_small" `Quick test_budget_too_small;
          Alcotest.test_case "zero" `Quick test_budget_zero;
          Alcotest.test_case "exn_raises" `Quick test_budget_exn_raises;
        ] );
      "cache_control", [ Alcotest.test_case "ephemeral" `Quick test_ephemeral ];
      ( "anthropic_options",
        [
          Alcotest.test_case "default" `Quick test_default_options;
          Alcotest.test_case "round_trip" `Quick test_provider_options_round_trip;
          Alcotest.test_case "empty" `Quick test_provider_options_empty;
        ] );
      ( "cache_control_options",
        [
          Alcotest.test_case "round_trip" `Quick test_cache_control_round_trip;
          Alcotest.test_case "none" `Quick test_cache_control_none;
          Alcotest.test_case "gadt_isolation" `Quick test_gadt_isolation;
        ] );
    ]
