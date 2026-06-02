open Alcotest
module Provider_options = Ai_provider.Provider_options
module Cache_control = Ai_provider_openrouter.Cache_control
module Cache_control_options = Ai_provider_openrouter.Cache_control_options
module Anthropic_cache_control = Ai_provider_anthropic.Cache_control
module Anthropic_cache_control_options = Ai_provider_anthropic.Cache_control_options

(* The OpenRouter [Cache_control.t] is a record nominally distinct from the
   Anthropic one. We compare by serializing through [to_json] so equality
   reflects observable wire shape. *)
let check_cache_eq ~msg expected actual =
  let s_expected = Yojson.Basic.to_string (Cache_control.to_json expected) in
  let s_actual = Yojson.Basic.to_string (Cache_control.to_json actual) in
  (check string) msg s_expected s_actual

let test_round_trip_openrouter_key () =
  let po = Cache_control_options.with_cache_control ~cache_control:Cache_control.ephemeral Provider_options.empty in
  match Cache_control_options.get_cache_control po with
  | None -> failf "expected Some, got None"
  | Some cc -> check_cache_eq ~msg:"openrouter round trip" Cache_control.ephemeral cc

let test_fallback_to_anthropic_key () =
  let po =
    Anthropic_cache_control_options.with_cache_control ~cache_control:Anthropic_cache_control.ephemeral
      Provider_options.empty
  in
  match Cache_control_options.get_cache_control po with
  | None -> failf "expected fallback to Anthropic key"
  | Some cc -> check_cache_eq ~msg:"anthropic fallback" Cache_control.ephemeral cc

let test_openrouter_wins_when_both_set () =
  (* Mirrors upstream [openrouter.cacheControl ?? anthropic.cacheControl]:
     when both are present, the OpenRouter key takes precedence. *)
  let po =
    Provider_options.empty
    |> Anthropic_cache_control_options.with_cache_control ~cache_control:Anthropic_cache_control.ephemeral
    |> Cache_control_options.with_cache_control ~cache_control:Cache_control.ephemeral_1h
  in
  match Cache_control_options.get_cache_control po with
  | None -> failf "expected Some"
  | Some cc -> check_cache_eq ~msg:"openrouter wins" Cache_control.ephemeral_1h cc

let test_neither_set () =
  match Cache_control_options.get_cache_control Provider_options.empty with
  | None -> ()
  | Some _ -> failf "expected None"

let test_fallback_preserves_ttl_1h () =
  let po =
    Anthropic_cache_control_options.with_cache_control ~cache_control:Anthropic_cache_control.ephemeral_1h
      Provider_options.empty
  in
  match Cache_control_options.get_cache_control po with
  | None -> failf "expected Some"
  | Some cc -> check_cache_eq ~msg:"ttl 1h preserved" Cache_control.ephemeral_1h cc

let test_fallback_preserves_ttl_5m () =
  let anthropic_5m = { Anthropic_cache_control.cache_type = Ephemeral; ttl = Some Anthropic_cache_control.Ttl_5m } in
  let openrouter_5m = { Cache_control.cache_type = Ephemeral; ttl = Some Cache_control.Ttl_5m } in
  let po = Anthropic_cache_control_options.with_cache_control ~cache_control:anthropic_5m Provider_options.empty in
  match Cache_control_options.get_cache_control po with
  | None -> failf "expected Some"
  | Some cc -> check_cache_eq ~msg:"ttl 5m preserved" openrouter_5m cc

let () =
  run "Cache_control_options"
    [
      ( "resolution",
        [
          test_case "openrouter key round trip" `Quick test_round_trip_openrouter_key;
          test_case "fallback to anthropic key" `Quick test_fallback_to_anthropic_key;
          test_case "openrouter wins when both set" `Quick test_openrouter_wins_when_both_set;
          test_case "neither set returns None" `Quick test_neither_set;
        ] );
      ( "ttl_preservation",
        [
          test_case "ttl 1h preserved on fallback" `Quick test_fallback_preserves_ttl_1h;
          test_case "ttl 5m preserved on fallback" `Quick test_fallback_preserves_ttl_5m;
        ] );
    ]
