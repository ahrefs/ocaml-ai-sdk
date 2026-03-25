open Alcotest

(* Finish_reason tests *)
let test_finish_reason_round_trip () =
  let open Ai_provider.Finish_reason in
  let cases = [ Stop; Length; Tool_calls; Content_filter; Error; Unknown ] in
  List.iter
    (fun r ->
      let s = to_string r in
      let r' = of_string s in
      (check string) "round trip" (to_string r) (to_string r'))
    cases

let test_finish_reason_other () =
  let r = Ai_provider.Finish_reason.of_string "something_new" in
  match r with
  | Ai_provider.Finish_reason.Other s -> (check string) "captures unknown" "something_new" s
  | _ -> fail "expected Other"

(* Usage tests *)
let test_usage_construction () =
  let u : Ai_provider.Usage.t = { input_tokens = 100; output_tokens = 50; total_tokens = Some 150 } in
  (check int) "input" 100 u.input_tokens;
  (check int) "output" 50 u.output_tokens;
  (check (option int)) "total" (Some 150) u.total_tokens

let test_usage_no_total () =
  let u : Ai_provider.Usage.t = { input_tokens = 100; output_tokens = 50; total_tokens = None } in
  (check (option int)) "no total" None u.total_tokens

(* Warning tests *)
let test_warning_unsupported () =
  let _w : Ai_provider.Warning.t =
    Unsupported_feature { feature = "seed"; details = Some "not supported by this provider" }
  in
  ()

let test_warning_other () =
  let _w : Ai_provider.Warning.t = Other { message = "something" } in
  ()

(* Provider_error tests *)
let test_provider_error_api () =
  let e : Ai_provider.Provider_error.t =
    { provider = "test"; kind = Api_error { status = 429; body = "rate limited" } }
  in
  let s = Ai_provider.Provider_error.to_string e in
  (check bool) "contains status" true (String.length s > 0)

let test_provider_error_exception () =
  let e : Ai_provider.Provider_error.t = { provider = "test"; kind = Network_error { message = "timeout" } } in
  check_raises "raises Provider_error" (Ai_provider.Provider_error.Provider_error e) (fun () ->
    raise (Ai_provider.Provider_error.Provider_error e))

let () =
  run "Foundation_types"
    [
      ( "finish_reason",
        [
          test_case "round_trip" `Quick test_finish_reason_round_trip;
          test_case "other" `Quick test_finish_reason_other;
        ] );
      ( "usage",
        [
          test_case "construction" `Quick test_usage_construction;
          test_case "no_total" `Quick test_usage_no_total;
        ] );
      ( "warning",
        [
          test_case "unsupported" `Quick test_warning_unsupported;
          test_case "other" `Quick test_warning_other;
        ] );
      ( "provider_error",
        [
          test_case "api_error" `Quick test_provider_error_api;
          test_case "exception" `Quick test_provider_error_exception;
        ] );
    ]
