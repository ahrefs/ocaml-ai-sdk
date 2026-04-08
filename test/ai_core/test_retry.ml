open Alcotest

(* Helper: create a retryable Provider_error *)
let retryable_error msg =
  Ai_provider.Provider_error.Provider_error
    { provider = "test"; kind = Api_error { status = 429; body = msg }; is_retryable = true }

(* Helper: create a non-retryable Provider_error *)
let non_retryable_error msg =
  Ai_provider.Provider_error.Provider_error
    { provider = "test"; kind = Api_error { status = 400; body = msg }; is_retryable = false }

let run_lwt f () = Lwt_main.run (f ())

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
      (Lwt.catch
         (fun () ->
           let%lwt _ =
             Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:1 (fun () ->
               incr call_count;
               Lwt.fail (retryable_error "overloaded"))
           in
           Lwt.return_none)
         (function
           | Ai_core.Retry.Retry_error { reason; errors; _ } -> Lwt.return_some (reason, errors)
           | exn -> Lwt.fail exn))
  in
  (* 1 initial + 2 retries = 3 calls *)
  (check int) "called 3 times" 3 !call_count;
  match result with
  | Some (reason, errors) ->
    (check string) "reason" "max_retries_exceeded" (Ai_core.Retry.reason_to_string reason);
    (check int) "3 errors" 3 (List.length errors)
  | None -> fail "expected Retry_error"

(* Test: non-retryable error is not retried, re-raised directly on first attempt *)
let test_non_retryable_not_retried () =
  let call_count = ref 0 in
  let caught = ref false in
  Lwt_main.run
    (Lwt.catch
       (fun () ->
         let%lwt _ =
           Ai_core.Retry.with_retries ~max_retries:2 (fun () ->
             incr call_count;
             Lwt.fail (non_retryable_error "bad request"))
         in
         Lwt.return_unit)
       (function
         | Ai_provider.Provider_error.Provider_error _ ->
           caught := true;
           Lwt.return_unit
         | exn -> Lwt.fail exn));
  (check int) "called once" 1 !call_count;
  (check bool) "caught original error" true !caught

(* Test: max_retries=0 disables retry, re-raises directly *)
let test_zero_retries_no_wrap () =
  let call_count = ref 0 in
  let caught_original = ref false in
  Lwt_main.run
    (Lwt.catch
       (fun () ->
         let%lwt _ =
           Ai_core.Retry.with_retries ~max_retries:0 (fun () ->
             incr call_count;
             Lwt.fail (retryable_error "overloaded"))
         in
         Lwt.return_unit)
       (function
         | Ai_provider.Provider_error.Provider_error _ ->
           caught_original := true;
           Lwt.return_unit
         | exn -> Lwt.fail exn));
  (check int) "called once" 1 !call_count;
  (check bool) "original error, not wrapped" true !caught_original

(* Test: succeeds on retry after initial failure *)
let test_succeeds_on_retry () =
  let call_count = ref 0 in
  let%lwt result =
    Ai_core.Retry.with_retries ~max_retries:2 ~initial_delay_ms:1 (fun () ->
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
    (Lwt.catch
       (fun () ->
         let%lwt _ =
           Ai_core.Retry.with_retries ~max_retries:2 (fun () ->
             incr call_count;
             Lwt.fail (Failure "boom"))
         in
         Lwt.return_unit)
       (function
         | Failure _ ->
           caught := true;
           Lwt.return_unit
         | exn -> Lwt.fail exn));
  (check int) "called once" 1 !call_count;
  (check bool) "caught Failure" true !caught

(* Test: non-retryable error after retryable errors wraps in Retry_error *)
let test_non_retryable_after_retries () =
  let call_count = ref 0 in
  let result =
    Lwt_main.run
      (Lwt.catch
         (fun () ->
           let%lwt _ =
             Ai_core.Retry.with_retries ~max_retries:3 ~initial_delay_ms:1 (fun () ->
               incr call_count;
               match !call_count with
               | 1 -> Lwt.fail (retryable_error "rate limit")
               | _ -> Lwt.fail (non_retryable_error "bad request"))
           in
           Lwt.return_none)
         (function
           | Ai_core.Retry.Retry_error { reason; errors; _ } -> Lwt.return_some (reason, errors)
           | exn -> Lwt.fail exn))
  in
  (check int) "called twice" 2 !call_count;
  match result with
  | Some (reason, errors) ->
    (check string) "reason" "error_not_retryable" (Ai_core.Retry.reason_to_string reason);
    (check int) "2 errors" 2 (List.length errors)
  | None -> fail "expected Retry_error"

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
        ] );
    ]
