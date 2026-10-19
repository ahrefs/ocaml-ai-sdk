open Alcotest

let run_lwt f () = Lwt_main.run (f ())

let lines ~stream_idle_timeout chunks =
  let timeouts = Ai_provider.Http_timeouts.create ~stream_idle_timeout () in
  Ai_provider.Http_client.(body_lines (response_of_chunks ~timeouts ~provider:"test" ~status:200 ~headers:[] chunks))

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
    ]
