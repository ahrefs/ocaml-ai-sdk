open Alcotest

(* Helper: create a retryable Provider_error *)
let retryable_error ?retry_after_s msg =
  Ai_provider.Provider_error.Provider_error
    (Ai_provider.Provider_error.make_api_error ~provider:"test" ~status:429 ~body:msg ~is_retryable:true ?retry_after_s
       ())

(* Helper: create a non-retryable Provider_error *)
let non_retryable_error msg =
  Ai_provider.Provider_error.Provider_error
    (Ai_provider.Provider_error.make_api_error ~provider:"test" ~status:400 ~body:msg ~is_retryable:false ())

let run_lwt f () = Lwt_main.run (f ())
let no_sleep _ = Lwt.return_unit
let no_jitter () = 0.5

(* Test: successful call is not retried *)
let test_success_no_retry () =
  let call_count = ref 0 in
  let%lwt result =
    Ai_core.Retry.with_retries ~max_retries:2 (fun () ->
      incr call_count;
      Lwt.return "ok")
  in
  (check string) "result" "ok" result;
  (check int) "called once" 1 !call_count;
  Lwt.return_unit

(* Test: retryable error is retried up to max_retries *)
let test_retryable_exhausts_retries () =
  let call_count = ref 0 in
  let result =
    Lwt_main.run
      (try%lwt
         let%lwt _ =
           Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:1 ~sleep:no_sleep ~random:no_jitter (fun () ->
             incr call_count;
             Lwt.fail (retryable_error "overloaded"))
         in
         Lwt.return_none
       with Ai_core.Retry.Retry_error { reason; errors; _ } -> Lwt.return_some (reason, errors))
  in
  (* 1 initial + 2 retries = 3 calls *)
  (check int) "called 3 times" 3 !call_count;
  match result with
  | None -> fail "expected Retry_error"
  | Some (reason, errors) ->
    (check string) "reason" "max_retries_exceeded" (Ai_core.Retry.reason_to_string reason);
    (check int) "3 errors" 3 (List.length errors)

(* Test: non-retryable error is not retried, re-raised directly on first attempt *)
let test_non_retryable_not_retried () =
  let call_count = ref 0 in
  let caught = ref false in
  Lwt_main.run
    (try%lwt
       let%lwt _ =
         Ai_core.Retry.with_retries ~max_retries:2 (fun () ->
           incr call_count;
           Lwt.fail (non_retryable_error "bad request"))
       in
       Lwt.return_unit
     with Ai_provider.Provider_error.Provider_error _ ->
       caught := true;
       Lwt.return_unit);
  (check int) "called once" 1 !call_count;
  (check bool) "caught original error" true !caught

(* Test: max_retries=0 disables retry, re-raises directly *)
let test_zero_retries_no_wrap () =
  let call_count = ref 0 in
  let caught_original = ref false in
  Lwt_main.run
    (try%lwt
       let%lwt _ =
         Ai_core.Retry.with_retries ~max_retries:0 (fun () ->
           incr call_count;
           Lwt.fail (retryable_error "overloaded"))
       in
       Lwt.return_unit
     with Ai_provider.Provider_error.Provider_error _ ->
       caught_original := true;
       Lwt.return_unit);
  (check int) "called once" 1 !call_count;
  (check bool) "original error, not wrapped" true !caught_original

(* Test: succeeds on retry after initial failure *)
let test_succeeds_on_retry () =
  let call_count = ref 0 in
  let%lwt result =
    Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:1 ~sleep:no_sleep ~random:no_jitter (fun () ->
      incr call_count;
      match !call_count with
      | 1 -> Lwt.fail (retryable_error "overloaded")
      | _ -> Lwt.return "recovered")
  in
  (check string) "result" "recovered" result;
  (check int) "called twice" 2 !call_count;
  Lwt.return_unit

(* Test: non-Provider errors are re-raised directly, never retried *)
let test_unknown_exception_not_retried () =
  let call_count = ref 0 in
  let caught = ref false in
  Lwt_main.run
    (try%lwt
       let%lwt _ =
         Ai_core.Retry.with_retries ~max_retries:2 (fun () ->
           incr call_count;
           Lwt.fail (Failure "boom"))
       in
       Lwt.return_unit
     with Failure _ ->
       caught := true;
       Lwt.return_unit);
  (check int) "called once" 1 !call_count;
  (check bool) "caught Failure" true !caught

(* Test: non-retryable error after retryable errors wraps in Retry_error *)
let test_non_retryable_after_retries () =
  let call_count = ref 0 in
  let result =
    Lwt_main.run
      (try%lwt
         let%lwt _ =
           Ai_core.Retry.with_retries ~max_retries:3 ~initial_delay_ms:1 ~sleep:no_sleep ~random:no_jitter (fun () ->
             incr call_count;
             match !call_count with
             | 1 -> Lwt.fail (retryable_error "rate limit")
             | _ -> Lwt.fail (non_retryable_error "bad request"))
         in
         Lwt.return_none
       with Ai_core.Retry.Retry_error { reason; errors; _ } -> Lwt.return_some (reason, errors))
  in
  (check int) "called twice" 2 !call_count;
  match result with
  | None -> fail "expected Retry_error"
  | Some (reason, errors) ->
    (check string) "reason" "error_not_retryable" (Ai_core.Retry.reason_to_string reason);
    (check int) "2 errors" 2 (List.length errors)

(* Test: transient network errors (Unix_error) are retried *)
let test_network_error_retried () =
  let call_count = ref 0 in
  let%lwt result =
    Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:1 ~sleep:no_sleep ~random:no_jitter (fun () ->
      incr call_count;
      match !call_count with
      | 1 -> Lwt.fail (Unix.Unix_error (Unix.ECONNRESET, "connect", ""))
      | _ -> Lwt.return "recovered")
  in
  (check string) "result" "recovered" result;
  (check int) "called twice" 2 !call_count;
  Lwt.return_unit

(* Test: network errors exhaust retries and wrap in Retry_error *)
let test_network_error_exhausts_retries () =
  let call_count = ref 0 in
  let result =
    Lwt_main.run
      (try%lwt
         let%lwt _ =
           Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:1 ~sleep:no_sleep ~random:no_jitter (fun () ->
             incr call_count;
             Lwt.fail (Unix.Unix_error (Unix.ECONNRESET, "connect", "")))
         in
         Lwt.return_none
       with Ai_core.Retry.Retry_error { reason; errors; _ } -> Lwt.return_some (reason, errors))
  in
  (check int) "called 3 times" 3 !call_count;
  match result with
  | None -> fail "expected Retry_error"
  | Some (reason, errors) ->
    (check string) "reason" "max_retries_exceeded" (Ai_core.Retry.reason_to_string reason);
    (check int) "3 errors" 3 (List.length errors)

(* Test: backoff_factor multiplies delay between retries *)
let test_backoff_factor_affects_delay () =
  let delays = ref [] in
  let sleep secs =
    delays := secs :: !delays;
    Lwt.return_unit
  in
  let call_count = ref 0 in
  (try
     ignore
       (Lwt_main.run
          (Ai_core.Retry.with_retries ~max_retries:3 ~initial_delay_ms:50 ~backoff_factor:2 ~sleep ~random:no_jitter
             (fun () ->
             incr call_count;
             Lwt.fail (retryable_error "overloaded")))
         : string)
   with Ai_core.Retry.Retry_error _ -> ());
  (check int) "called 4 times" 4 !call_count;
  let delays = List.rev !delays in
  (check (list (float 0.001))) "backoff delays" [ 0.050; 0.100; 0.200 ] delays

let test_retry_after_is_minimum_delay () =
  let delays = ref [] in
  let sleep delay =
    delays := delay :: !delays;
    Lwt.return_unit
  in
  let call_count = ref 0 in
  let result =
    Lwt_main.run
      (Ai_core.Retry.with_retries ~max_retries:1 ~initial_delay_ms:2000 ~sleep ~random:no_jitter (fun () ->
         incr call_count;
         match !call_count with
         | 1 -> Lwt.fail (retryable_error ~retry_after_s:5.0 "overloaded")
         | _ -> Lwt.return "ok"))
  in
  (check string) "result" "ok" result;
  (check int) "two attempts" 2 !call_count;
  (check (list (float 0.001))) "server minimum" [ 5.0 ] (List.rev !delays)

let test_retry_after_above_cap_stops () =
  let call_count = ref 0 in
  let slept = ref false in
  let sleep _ =
    slept := true;
    Lwt.return_unit
  in
  let result =
    try
      ignore
        (Lwt_main.run
           (Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:2000 ~max_retry_delay_ms:4000 ~sleep
              ~random:no_jitter (fun () ->
              incr call_count;
              Lwt.fail (retryable_error ~retry_after_s:5.0 "overloaded")))
          : string);
      None
    with Ai_core.Retry.Retry_error { reason; errors; _ } -> Some (reason, errors)
  in
  (check int) "one attempt" 1 !call_count;
  (check bool) "did not sleep" false !slept;
  match result with
  | None -> fail "expected Retry_error"
  | Some (reason, [ Ai_provider.Provider_error.Provider_error { retry_after_s = Some delay; _ } ]) ->
    (check string) "existing reason" "max_retries_exceeded" (Ai_core.Retry.reason_to_string reason);
    (check (float 0.001)) "original hint retained" 5.0 delay
  | Some _ -> fail "expected the original provider error"

let test_backoff_above_cap_is_clamped () =
  let delays = ref [] in
  let sleep delay =
    delays := delay :: !delays;
    Lwt.return_unit
  in
  let call_count = ref 0 in
  let result =
    Lwt_main.run
      (Ai_core.Retry.with_retries ~max_retries:1 ~initial_delay_ms:2000 ~max_retry_delay_ms:1000 ~sleep
         ~random:no_jitter (fun () ->
         incr call_count;
         match !call_count with
         | 1 -> Lwt.fail (retryable_error "overloaded")
         | _ -> Lwt.return "ok"))
  in
  (check string) "result" "ok" result;
  (check int) "two attempts" 2 !call_count;
  (check (list (float 0.001))) "clamped delay" [ 1.0 ] (List.rev !delays)

let test_backoff_does_not_overflow () =
  let delays = ref [] in
  let sleep delay =
    delays := delay :: !delays;
    Lwt.return_unit
  in
  (try
     ignore
       (Lwt_main.run
          (Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:max_int ~backoff_factor:2 ~max_retry_delay_ms:1
             ~sleep ~random:no_jitter (fun () -> Lwt.fail (retryable_error "overloaded")))
         : string)
   with Ai_core.Retry.Retry_error _ -> ());
  (check (list (float 0.0001))) "both delays stay capped" [ 0.001; 0.001 ] (List.rev !delays)

let test_missing_retry_after_uses_jittered_backoff () =
  let delays = ref [] in
  let sleep delay =
    delays := delay :: !delays;
    Lwt.return_unit
  in
  let call_count = ref 0 in
  let result =
    Lwt_main.run
      (Ai_core.Retry.with_retries ~max_retries:1 ~initial_delay_ms:2000 ~sleep
         ~random:(fun () -> 0.0)
         (fun () ->
           incr call_count;
           match !call_count with
           | 1 -> Lwt.fail (retryable_error "overloaded")
           | _ -> Lwt.return "ok"))
  in
  (check string) "result" "ok" result;
  (check (list (float 0.001))) "50% bounded jitter" [ 1.0 ] (List.rev !delays)

(* Test: negative max_retries raises invalid_arg *)
let test_negative_max_retries () =
  let caught = ref false in
  (try ignore (Lwt_main.run (Ai_core.Retry.with_retries ~max_retries:(-1) (fun () -> Lwt.return "ok")))
   with Invalid_argument _ -> caught := true);
  (check bool) "caught invalid_arg" true !caught

(* Test: backoff_factor < 1 raises invalid_arg *)
let test_invalid_backoff_factor () =
  let caught = ref false in
  (try ignore (Lwt_main.run (Ai_core.Retry.with_retries ~backoff_factor:0 (fun () -> Lwt.return "ok")))
   with Invalid_argument _ -> caught := true);
  (check bool) "caught invalid_arg" true !caught

let test_invalid_max_retry_delay () =
  let caught = ref false in
  (try ignore (Lwt_main.run (Ai_core.Retry.with_retries ~max_retry_delay_ms:(-1) (fun () -> Lwt.return "ok")) : string)
   with Invalid_argument _ -> caught := true);
  (check bool) "caught invalid_arg" true !caught

let () =
  run "Retry"
    [
      ( "with_retries",
        [
          test_case "success_no_retry" `Quick (run_lwt test_success_no_retry);
          test_case "retryable_exhausts" `Quick test_retryable_exhausts_retries;
          test_case "non_retryable_not_retried" `Quick test_non_retryable_not_retried;
          test_case "zero_retries" `Quick test_zero_retries_no_wrap;
          test_case "succeeds_on_retry" `Quick (run_lwt test_succeeds_on_retry);
          test_case "unknown_exception" `Quick test_unknown_exception_not_retried;
          test_case "non_retryable_after_retries" `Quick test_non_retryable_after_retries;
          test_case "network_error_retried" `Quick (run_lwt test_network_error_retried);
          test_case "network_error_exhausts" `Quick test_network_error_exhausts_retries;
          test_case "backoff_factor" `Quick test_backoff_factor_affects_delay;
          test_case "retry_after_minimum" `Quick test_retry_after_is_minimum_delay;
          test_case "retry_after_above_cap" `Quick test_retry_after_above_cap_stops;
          test_case "backoff_above_cap_clamped" `Quick test_backoff_above_cap_is_clamped;
          test_case "backoff_no_overflow" `Quick test_backoff_does_not_overflow;
          test_case "missing_retry_after_jitter" `Quick test_missing_retry_after_uses_jittered_backoff;
          test_case "negative_max_retries" `Quick test_negative_max_retries;
          test_case "invalid_backoff_factor" `Quick test_invalid_backoff_factor;
          test_case "invalid_max_retry_delay" `Quick test_invalid_max_retry_delay;
        ] );
    ]
