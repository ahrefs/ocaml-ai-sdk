open Alcotest

let run_lwt f () = Lwt_main.run (f ())

let lines ~stream_idle_timeout chunks =
  let timeouts = Ai_provider.Http_timeouts.create ~stream_idle_timeout () in
  Ai_provider.Http_client.(
    body_lines (For_testing.response_of_chunks ~timeouts ~provider:"test" ~status:200 ~headers:[] chunks))

(* A body whose stream emits each chunk after [delay] seconds, then ends. *)
let timed_chunks ~delay chunks =
  let pending = ref chunks in
  Lwt_stream.from (fun () ->
    match !pending with
    | [] -> Lwt.return None
    | c :: rest ->
      pending := rest;
      let%lwt () = Lwt_unix.sleep delay in
      Lwt.return (Some c))

(* An idle timeout fails the pending read with a Stream_idle error, then the
   stream ends. *)
let test_stream_idle_fires () =
  let stalled, push = Lwt_stream.create () in
  push (Some "data: first\n");
  let lines = lines ~stream_idle_timeout:0.2 stalled in
  let%lwt first = Lwt_stream.get lines in
  (check (option string)) "first line" (Some "data: first") first;
  let%lwt () =
    match%lwt Lwt_stream.get lines with
    | _ -> fail "expected a Stream_idle timeout"
    | exception Ai_provider.Provider_error.Provider_error { kind = Timeout { phase = Stream_idle; _ }; _ } ->
      Lwt.return_unit
  in
  let%lwt next = Lwt_stream.get lines in
  (check (option string)) "end of stream after idle" None next;
  Lwt.return_unit

(* Each arriving chunk resets the idle timer, so a steady drip below the
   idle threshold streams to completion. *)
let test_stream_idle_resets () =
  let chunks = [ "data: 5\n"; "data: 4\n"; "data: 3\n"; "data: 2\n"; "data: 1\n" ] in
  let%lwt all = Lwt_stream.to_list (lines ~stream_idle_timeout:0.3 (timed_chunks ~delay:0.1 chunks)) in
  (check int) "five lines" 5 (List.length all);
  Lwt.return_unit

(* End-of-body without a trailing newline still flushes the buffered data. *)
let test_trailing_data_flushed () =
  let%lwt all = Lwt_stream.to_list (lines ~stream_idle_timeout:5.0 (Lwt_stream.of_list [ "alpha\nbeta" ])) in
  (check (list string)) "both lines emitted" [ "alpha"; "beta" ] all;
  Lwt.return_unit

(* CRs are stripped; lines split on LF only. *)
let test_crlf_split () =
  let%lwt all = Lwt_stream.to_list (lines ~stream_idle_timeout:5.0 (Lwt_stream.of_list [ "one\r\ntwo\r\nthree\n" ])) in
  (check (list string)) "CRLF stripped" [ "one"; "two"; "three" ] all;
  Lwt.return_unit

(* [Provider_error.make_timeout] applies the phase-based retryability rule
   that the [Http_client.post] timeout translation relies on. *)
let test_timeout_phase_retryability () =
  let req = Ai_provider.Provider_error.make_timeout ~provider:"p" ~phase:Request_headers ~elapsed_s:1.0 ~limit_s:1.0 in
  (check bool) "Request_headers not retryable" false req.is_retryable;
  let idle = Ai_provider.Provider_error.make_timeout ~provider:"p" ~phase:Stream_idle ~elapsed_s:1.0 ~limit_s:1.0 in
  (check bool) "Stream_idle retryable" true idle.is_retryable

(* lwt_ppx's [match%lwt] raises at once on a promise that has already failed.
   [body_string] and [error_body] must still hand back a promise. *)
let test_reads_return_promises () =
  let failing_response () =
    Ai_provider.Http_client.For_testing.response_of_chunks ~timeouts:Ai_provider.Http_timeouts.default ~provider:"test"
      ~status:200 ~headers:[]
      (Lwt_stream.from (fun () -> Lwt.fail (Failure "boom")))
  in
  let returns_promise name read =
    match read (failing_response ()) with
    | (_ : unit Lwt.t) -> ()
    | exception exn -> failf "%s raised %s instead of returning a promise" name (Printexc.to_string exn)
  in
  returns_promise "body_string" (fun r -> Lwt.map (fun (_ : string) -> ()) (Ai_provider.Http_client.body_string r));
  returns_promise "error_body" (fun r -> Lwt.map (fun (_ : string) -> ()) (Ai_provider.Http_client.error_body r))

let response ?abort_signal ~status chunks =
  Ai_provider.Http_client.For_testing.response_of_chunks ?abort_signal ~timeouts:Ai_provider.Http_timeouts.default
    ~provider:"test" ~status ~headers:[] (Lwt_stream.of_list chunks)

let contains ~sub s =
  let n = String.length sub in
  let rec from i = i + n <= String.length s && (String.equal (String.sub s i n) sub || from (i + 1)) in
  from 0

let post url =
  Ai_provider.Http_client.post ~timeouts:Ai_provider.Http_timeouts.default ~provider:"test" ~headers:[] ~body:"{}" url

let expect_network_error ~retryable promise =
  match%lwt promise with
  | _ -> fail "expected a network error"
  | exception Ai_provider.Provider_error.Provider_error { kind = Network_error { message }; is_retryable; _ } ->
    (check bool) "retryable" retryable is_retryable;
    Lwt.return message

let test_non_http_scheme_rejected () =
  let%lwt (_ : string) = expect_network_error ~retryable:false (post "file:///etc/hostname") in
  Lwt.return_unit

(* libcurl rejects a string option over 8 MB, before any connection. The
   rejected option surfaces as a non-retryable Network_error, not as a
   Curl.CurlException. *)
let test_rejected_option_not_retryable () =
  let%lwt message = expect_network_error ~retryable:false (post ("http://127.0.0.1/" ^ String.make 8_000_000 'a')) in
  (check bool) "names the code" true (contains ~sub:"(CURLE_BAD_FUNCTION_ARGUMENT)" message);
  Lwt.return_unit

let expect_aborted promise =
  match%lwt promise with
  | _ -> fail "expected Aborted"
  | exception Ai_provider.Abort_signal.Aborted _ -> Lwt.return_unit

(* A transport failure ends the error body read; the part that arrived is kept. *)
let test_error_body_partial () =
  let failed = ref false in
  let chunks =
    Lwt_stream.from (fun () ->
      match !failed with
      | true ->
        Lwt.fail
          (Ai_provider.Provider_error.Provider_error
             (Ai_provider.Provider_error.make_timeout ~provider:"test" ~phase:Stream_idle ~elapsed_s:1.0 ~limit_s:1.0))
      | false ->
        failed := true;
        Lwt.return_some "partial")
  in
  let response =
    Ai_provider.Http_client.For_testing.response_of_chunks ~timeouts:Ai_provider.Http_timeouts.default ~provider:"test"
      ~status:503 ~headers:[] chunks
  in
  let%lwt body = Ai_provider.Http_client.error_body response in
  (check string) "partial body" "partial" body;
  Lwt.return_unit

let test_error_body_capped () =
  let response = response ~status:500 [ String.make 40000 'x'; String.make 40000 'y' ] in
  let%lwt body = Ai_provider.Http_client.error_body response in
  (check int) "capped at 64 KiB" 65536 (String.length body);
  Lwt.return_unit

(* One chunk holds several lines. After the abort, the lines still queued from
   that chunk are not returned. *)
let test_abort_with_queued_lines () =
  let signal, abort = Ai_provider.Abort_signal.create () in
  let lines =
    Ai_provider.Http_client.body_lines
      (response ~abort_signal:signal ~status:200 [ "data: one\n\ndata: two\n\ndata: three\n\n" ])
  in
  let%lwt first = Lwt_stream.get lines in
  (check (option string)) "first line" (Some "data: one") first;
  abort ();
  expect_aborted (Lwt.apply Lwt_stream.get lines)

let () =
  run "Http_client"
    [
      ( "idle_timeout",
        [
          test_case "fires after first chunk" `Quick (run_lwt test_stream_idle_fires);
          test_case "resets on each chunk" `Quick (run_lwt test_stream_idle_resets);
        ] );
      ( "line_splitting",
        [
          test_case "trailing data flushed" `Quick (run_lwt test_trailing_data_flushed);
          test_case "CRLF stripped" `Quick (run_lwt test_crlf_split);
        ] );
      "provider_error", [ test_case "timeout phase retryability" `Quick test_timeout_phase_retryability ];
      "promises", [ test_case "failed reads return promises" `Quick test_reads_return_promises ];
      ( "error_body",
        [
          test_case "partial body kept" `Quick (run_lwt test_error_body_partial);
          test_case "capped" `Quick (run_lwt test_error_body_capped);
        ] );
      ( "failure_classification",
        [
          test_case "non-http scheme rejected" `Quick (run_lwt test_non_http_scheme_rejected);
          test_case "rejected option not retryable" `Quick (run_lwt test_rejected_option_not_retryable);
        ] );
      "abort", [ test_case "lines still queued" `Quick (run_lwt test_abort_with_queued_lines) ];
    ]
