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
    { provider = "test"; kind = Api_error { status = 429; body = "rate limited" }; is_retryable = false }
  in
  let s = Ai_provider.Provider_error.to_string e in
  (check bool) "contains status" true (String.length s > 0)

let test_provider_error_exception () =
  let e : Ai_provider.Provider_error.t =
    { provider = "test"; kind = Network_error { message = "timeout" }; is_retryable = false }
  in
  check_raises "raises Provider_error" (Ai_provider.Provider_error.Provider_error e) (fun () ->
    raise (Ai_provider.Provider_error.Provider_error e))

let test_provider_error_retryable () =
  let e : Ai_provider.Provider_error.t =
    { provider = "test"; kind = Api_error { status = 429; body = "rate limited" }; is_retryable = true }
  in
  (check bool) "is retryable" true e.is_retryable

let test_provider_error_not_retryable () =
  let e : Ai_provider.Provider_error.t =
    { provider = "test"; kind = Api_error { status = 400; body = "bad request" }; is_retryable = false }
  in
  (check bool) "not retryable" false e.is_retryable

(* make_api_error status-code default tests — matches upstream APICallError constructor *)
let test_make_api_error_429_default_retryable () =
  let e = Ai_provider.Provider_error.make_api_error ~provider:"test" ~status:429 ~body:"rate limited" () in
  (check bool) "429 retryable by default" true e.is_retryable

let test_make_api_error_500_default_retryable () =
  let e = Ai_provider.Provider_error.make_api_error ~provider:"test" ~status:500 ~body:"server error" () in
  (check bool) "500 retryable by default" true e.is_retryable

let test_make_api_error_408_default_retryable () =
  let e = Ai_provider.Provider_error.make_api_error ~provider:"test" ~status:408 ~body:"timeout" () in
  (check bool) "408 retryable by default" true e.is_retryable

let test_make_api_error_409_default_retryable () =
  let e = Ai_provider.Provider_error.make_api_error ~provider:"test" ~status:409 ~body:"conflict" () in
  (check bool) "409 retryable by default" true e.is_retryable

let test_make_api_error_400_default_not_retryable () =
  let e = Ai_provider.Provider_error.make_api_error ~provider:"test" ~status:400 ~body:"bad request" () in
  (check bool) "400 not retryable by default" false e.is_retryable

let test_make_api_error_override () =
  let e = Ai_provider.Provider_error.make_api_error ~provider:"test" ~status:500 ~body:"error" ~is_retryable:false () in
  (check bool) "override to non-retryable" false e.is_retryable

let test_timeout_request_headers_not_retryable () =
  let e =
    Ai_provider.Provider_error.make_timeout
      ~provider:"openai"
      ~phase:Request_headers
      ~elapsed_s:600.0
      ~limit_s:600.0
  in
  (check bool) "request_headers not retryable" false e.is_retryable

let test_timeout_stream_idle_retryable () =
  let e =
    Ai_provider.Provider_error.make_timeout
      ~provider:"anthropic"
      ~phase:Stream_idle
      ~elapsed_s:300.0
      ~limit_s:300.0
  in
  (check bool) "stream_idle retryable" true e.is_retryable

(* String-contains helper; used to assert phase/elapsed/limit appear in
   the formatted message. *)
let contains ~sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  let rec loop i =
    i + sub_len <= s_len
    && (String.equal (String.sub s i sub_len) sub || loop (i + 1))
  in
  loop 0

let test_timeout_to_string_formats_all_fields () =
  let e =
    Ai_provider.Provider_error.make_timeout
      ~provider:"openai"
      ~phase:Request_headers
      ~elapsed_s:600.0
      ~limit_s:600.0
  in
  let s = Ai_provider.Provider_error.to_string e in
  (check bool) "mentions provider" true (contains ~sub:"openai" s);
  (check bool) "mentions phase label" true (contains ~sub:"response headers" s);
  (check bool) "mentions elapsed" true (contains ~sub:"600.0s" s);
  (check bool) "mentions limit prefix" true (contains ~sub:"limit: 600.0" s)

let test_timeout_to_string_uses_stream_phase_label () =
  let e =
    Ai_provider.Provider_error.make_timeout
      ~provider:"anthropic"
      ~phase:Stream_idle
      ~elapsed_s:300.0
      ~limit_s:300.0
  in
  let s = Ai_provider.Provider_error.to_string e in
  (check bool) "uses streaming body chunk label" true (contains ~sub:"streaming body chunk" s)

let () =
  run "Foundation_types"
    [
      ( "finish_reason",
        [
          test_case "round_trip" `Quick test_finish_reason_round_trip; test_case "other" `Quick test_finish_reason_other;
        ] );
      ( "usage",
        [ test_case "construction" `Quick test_usage_construction; test_case "no_total" `Quick test_usage_no_total ] );
      ( "warning",
        [ test_case "unsupported" `Quick test_warning_unsupported; test_case "other" `Quick test_warning_other ] );
      ( "provider_error",
        [
          test_case "api_error" `Quick test_provider_error_api;
          test_case "exception" `Quick test_provider_error_exception;
          test_case "retryable" `Quick test_provider_error_retryable;
          test_case "not_retryable" `Quick test_provider_error_not_retryable;
        ] );
      ( "make_api_error_defaults",
        [
          test_case "429_default_retryable" `Quick test_make_api_error_429_default_retryable;
          test_case "500_default_retryable" `Quick test_make_api_error_500_default_retryable;
          test_case "408_default_retryable" `Quick test_make_api_error_408_default_retryable;
          test_case "409_default_retryable" `Quick test_make_api_error_409_default_retryable;
          test_case "400_default_not_retryable" `Quick test_make_api_error_400_default_not_retryable;
          test_case "override" `Quick test_make_api_error_override;
          test_case "timeout request_headers not retryable" `Quick test_timeout_request_headers_not_retryable;
          test_case "timeout stream_idle retryable" `Quick test_timeout_stream_idle_retryable;
          test_case "timeout to_string formats all fields" `Quick test_timeout_to_string_formats_all_fields;
          test_case "timeout to_string uses stream phase label" `Quick test_timeout_to_string_uses_stream_phase_label;
        ] );
    ]
