(** Tests for Http_client's idle-timeout body wrapper.

    These tests exercise our line-splitting and idle-timeout logic directly
    against synthetic [Cohttp_lwt.Body.t] values built from in-memory streams.
    No socket is opened, so the suite runs fine inside opam's network-isolated
    sandbox.

    The thin [post] wrapper around [Cohttp_lwt_unix.Client.post] is not
    unit-tested here: it is a 4-line [try%lwt] translating [Lwt_unix.Timeout]
    into a [Provider_error]. Exercising that translation requires either a
    real socket (incompatible with the opam sandbox) or stubbing cohttp
    itself. The retryability and phase mapping it depends on are covered by
    the [Provider_error.make_timeout] tests below. *)

open Alcotest

let run_lwt f () = Lwt_main.run (f ())

let body_of_chunks chunks =
  let stream = Lwt_stream.of_list chunks in
  Cohttp_lwt.Body.of_stream stream

(* Build a body whose stream emits each chunk after [delay] seconds, then
   never produces another chunk (the final [Lwt_stream.get] blocks forever).
   This lets us drive the idle-timeout race inside [wrap_body_with_idle_timeout]
   without any I/O. *)
let body_of_timed_chunks ~delay chunks =
  let pending = ref chunks in
  let stream =
    Lwt_stream.from (fun () ->
      match !pending with
      | [] ->
        let%lwt () = Lwt_unix.sleep 3600.0 in
        Lwt.return None
      | c :: rest ->
        pending := rest;
        let%lwt () = Lwt_unix.sleep delay in
        Lwt.return (Some c))
  in
  Cohttp_lwt.Body.of_stream stream

(* Stream-idle timeout closes the consumer stream cleanly after the first
   chunk when no further chunk arrives within [stream_idle_timeout]. *)
let test_stream_idle_fires () =
  let body = body_of_timed_chunks ~delay:0.0 [ "data: first\n" ] in
  let timeouts = Ai_provider.Http_timeouts.create ~stream_idle_timeout:0.2 () in
  let lines = Ai_provider.Http_client.wrap_body_with_idle_timeout ~timeouts ~provider:"test" body in
  let%lwt first = Lwt_stream.get lines in
  (check (option string)) "first line" (Some "data: first") first;
  let%lwt next = Lwt_stream.get lines in
  (check (option string)) "end of stream after idle" None next;
  Lwt.return_unit

(* Each arriving chunk resets the idle timer, so a steady drip below the
   idle threshold streams to completion. *)
let test_stream_idle_resets () =
  let chunks = [ "data: 5\n"; "data: 4\n"; "data: 3\n"; "data: 2\n"; "data: 1\n" ] in
  let body = body_of_timed_chunks ~delay:0.1 chunks in
  let timeouts = Ai_provider.Http_timeouts.create ~stream_idle_timeout:0.3 () in
  let lines = Ai_provider.Http_client.wrap_body_with_idle_timeout ~timeouts ~provider:"test" body in
  let%lwt all = Lwt_stream.to_list lines in
  (check int) "five lines" 5 (List.length all);
  Lwt.return_unit

(* End-of-body without a trailing newline still flushes the buffered data. *)
let test_trailing_data_flushed () =
  let body = body_of_chunks [ "alpha\nbeta" ] in
  let timeouts = Ai_provider.Http_timeouts.create ~stream_idle_timeout:5.0 () in
  let lines = Ai_provider.Http_client.wrap_body_with_idle_timeout ~timeouts ~provider:"test" body in
  let%lwt all = Lwt_stream.to_list lines in
  (check (list string)) "both lines emitted" [ "alpha"; "beta" ] all;
  Lwt.return_unit

(* CRs are stripped; lines split on LF only. *)
let test_crlf_split () =
  let body = body_of_chunks [ "one\r\ntwo\r\nthree\n" ] in
  let timeouts = Ai_provider.Http_timeouts.create ~stream_idle_timeout:5.0 () in
  let lines = Ai_provider.Http_client.wrap_body_with_idle_timeout ~timeouts ~provider:"test" body in
  let%lwt all = Lwt_stream.to_list lines in
  (check (list string)) "CRLF stripped" [ "one"; "two"; "three" ] all;
  Lwt.return_unit

(* [Provider_error.make_timeout] applies the phase-based retryability rule
   that the [Http_client.post] timeout translation relies on. *)
let test_timeout_phase_retryability () =
  let req =
    Ai_provider.Provider_error.make_timeout ~provider:"p" ~phase:Request_headers ~elapsed_s:1.0 ~limit_s:1.0
  in
  (check bool) "Request_headers not retryable" false req.is_retryable;
  let idle =
    Ai_provider.Provider_error.make_timeout ~provider:"p" ~phase:Stream_idle ~elapsed_s:1.0 ~limit_s:1.0
  in
  (check bool) "Stream_idle retryable" true idle.is_retryable

let () =
  (* The library re-raises idle-timeout errors to Lwt.async_exception_hook
     (which would otherwise exit the process). This binary runs only these
     tests, so a global override is fine — no restore needed. *)
  (Lwt.async_exception_hook := fun _ -> ());
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
