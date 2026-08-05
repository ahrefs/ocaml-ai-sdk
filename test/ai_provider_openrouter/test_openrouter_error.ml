open Alcotest

module E = Ai_provider_openrouter.Openrouter_error

let api_error_kind err =
  match err.Ai_provider.Provider_error.kind with
  | Api_error { status; body } -> status, body, err.is_retryable
  | _ -> fail "expected Api_error"

(* Regression: the authoritative HTTP transport status must win over the inner
   provider error.code, so retryability is not silently flipped. A gateway 503
   wrapping an inner {code:400} must stay retryable. *)
let test_of_response_http_status_wins () =
  let body = {|{"error":{"code":400,"message":"upstream refused","metadata":{"provider_name":"anthropic"}}}|} in
  let status, _body, is_retryable = api_error_kind (E.of_response ~status:503 ~body) in
  (check int) "http status preserved" 503 status;
  (check bool) "retryable (5xx gateway)" true is_retryable

(* Regression: error.code encoded as a JSON string (as some upstreams emit) must
   still be parsed so a 429 rate-limit is classified retryable, not defaulted to 200. *)
let test_of_error_json_string_code () =
  let error_json = Yojson.Basic.from_string {|{"code":"429","message":"Rate limit"}|} in
  let status, _body, is_retryable = api_error_kind (E.of_error_json error_json) in
  (check int) "string code parsed" 429 status;
  (check bool) "retryable (429)" true is_retryable

let test_of_error_json_float_code () =
  let error_json = Yojson.Basic.from_string {|{"code":502.0,"message":"Bad gateway"}|} in
  let status, _body, is_retryable = api_error_kind (E.of_error_json error_json) in
  (check int) "float code parsed" 502 status;
  (check bool) "retryable (5xx)" true is_retryable

(* No parseable code and no HTTP status -> default 200, not retryable. *)
let test_of_error_json_missing_code_defaults () =
  let error_json = Yojson.Basic.from_string {|{"message":"mystery"}|} in
  let status, _body, is_retryable = api_error_kind (E.of_error_json error_json) in
  (check int) "default status" 200 status;
  (check bool) "not retryable" false is_retryable

(* The readable message digs into metadata.raw (a JSON-encoded upstream error) and
   prefixes the provider name, rather than surfacing the generic envelope message. *)
let test_readable_message_from_raw () =
  let body =
    {|{"error":{"message":"Provider returned error","metadata":{"provider_name":"anthropic","raw":"{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}"}}}|}
  in
  let _status, body, _retryable = api_error_kind (E.of_response ~status:502 ~body) in
  (check string) "extracted upstream message" "[anthropic] Overloaded" body

let test_readable_message_appends_error_type () =
  let error_json =
    Yojson.Basic.from_string
      {|{"code":429,"message":"Rate limit exceeded","metadata":{"error_type":"rate_limit_exceeded"}}|}
  in
  let _status, body, _retryable = api_error_kind (E.of_error_json error_json) in
  (check string) "error_type appended" "Rate limit exceeded (rate_limit_exceeded)" body

(* Non-JSON and JSON-without-error bodies fall back to the raw body verbatim. *)
let test_of_response_non_json_body () =
  let _status, body, _retryable = api_error_kind (E.of_response ~status:500 ~body:"Internal Server Error") in
  (check string) "raw body preserved" "Internal Server Error" body

let test_of_response_json_without_error () =
  let _status, body, _retryable = api_error_kind (E.of_response ~status:500 ~body:{|{"detail":"nope"}|}) in
  (check string) "raw body preserved" {|{"detail":"nope"}|} body

let test_of_response_preserves_retry_after status () =
  let err =
    E.of_response_with_retry_after ~status ~body:{|{"error":{"message":"try later"}}|} ~retry_after:(Some " 5 ")
  in
  (check (option (float 0.001))) "retry-after preserved" (Some 5.0) err.retry_after_s

let test_invalid_retry_after () =
  List.iter
    (fun value ->
      let err = E.of_response_with_retry_after ~status:503 ~body:"overloaded" ~retry_after:(Some value) in
      (check (option (float 0.001))) value None err.retry_after_s)
    [ ""; "-1"; "+1"; "1.5"; "tomorrow"; "999999999999999999999999999999999999" ]

let () =
  run "Openrouter_error"
    [
      ( "of_response",
        [
          test_case "http_status_wins" `Quick test_of_response_http_status_wins;
          test_case "readable_from_raw" `Quick test_readable_message_from_raw;
          test_case "non_json_body" `Quick test_of_response_non_json_body;
          test_case "json_without_error" `Quick test_of_response_json_without_error;
          test_case "429_retry_after" `Quick (test_of_response_preserves_retry_after 429);
          test_case "503_retry_after" `Quick (test_of_response_preserves_retry_after 503);
          test_case "invalid_retry_after" `Quick test_invalid_retry_after;
        ] );
      ( "of_error_json",
        [
          test_case "string_code" `Quick test_of_error_json_string_code;
          test_case "float_code" `Quick test_of_error_json_float_code;
          test_case "missing_code_defaults" `Quick test_of_error_json_missing_code_defaults;
          test_case "error_type_appended" `Quick test_readable_message_appends_error_type;
        ] );
    ]
