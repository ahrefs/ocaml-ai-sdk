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
  returns_promise "body_string" (fun r -> Lwt.map ignore (Ai_provider.Http_client.body_string r));
  returns_promise "error_body" (fun r -> Lwt.map ignore (Ai_provider.Http_client.error_body r))

(* Loopback server. Each test serves one connection with a canned reply. *)

type reply =
  | Reply of string  (** Written after the request head arrives, then the connection closes. *)
  | Greet of string  (** Written on accept, without reading the request. *)
  | Hang  (** The connection is accepted and never answered. *)

let contains ~sub s =
  let n = String.length sub in
  let rec from i = i + n <= String.length s && (String.equal (String.sub s i n) sub || from (i + 1)) in
  from 0

let read_head fd =
  let buf = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match%lwt Lwt_unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Lwt.return (Buffer.contents buf)
    | n ->
      Buffer.add_subbytes buf chunk 0 n;
      (match contains ~sub:"\r\n\r\n" (Buffer.contents buf) with
      | true -> Lwt.return (Buffer.contents buf)
      | false -> loop ())
  in
  loop ()

let write_all fd s =
  let%lwt (_ : int) = Lwt_unix.write_string fd s 0 (String.length s) in
  Lwt.return_unit

(* Half-closes, then drains what the client still sends before closing: closing
   with unread data sends an RST, which can drop the reply before curl reads it. *)
let finish fd =
  Lwt_unix.shutdown fd SHUTDOWN_SEND;
  let chunk = Bytes.create 4096 in
  let rec drain () =
    match%lwt Lwt_unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Lwt.return_unit
    | _ -> drain ()
  in
  let%lwt () = try%lwt drain () with Unix.Unix_error _ -> Lwt.return_unit in
  Lwt_unix.close fd

let answer fd data =
  let%lwt () = write_all fd data in
  Lwt.dont_wait (fun () -> finish fd) (fun (_ : exn) -> ());
  Lwt.return_unit

(* Returns the port and a promise of the request head the client sent. *)
let listen_loopback ~backlog =
  let sock = Lwt_unix.socket PF_INET SOCK_STREAM 0 in
  let%lwt () = Lwt_unix.bind sock (ADDR_INET (Unix.inet_addr_loopback, 0)) in
  Lwt_unix.listen sock backlog;
  match Lwt_unix.getsockname sock with
  | ADDR_INET (_, port) -> Lwt.return (sock, port)
  | ADDR_UNIX path -> Printf.ksprintf invalid_arg "listen_loopback: unexpected unix socket %s" path

let serve_once reply =
  let%lwt sock, port = listen_loopback ~backlog:1 in
  let request =
    let%lwt fd, _ = Lwt_unix.accept sock in
    let%lwt () = Lwt_unix.close sock in
    match reply with
    | Hang -> fst (Lwt.wait ())
    | Greet data ->
      let%lwt () = answer fd data in
      Lwt.return ""
    | Reply data ->
      let%lwt head = read_head fd in
      let%lwt () = answer fd data in
      Lwt.return head
  in
  Lwt.return (port, request)

(* Answers [count] connections concurrently, each [delay] seconds after its
   request head arrives. *)
let serve_slowly ~count ~delay data =
  let%lwt sock, port = listen_loopback ~backlog:count in
  let respond fd =
    let%lwt (_ : string) = read_head fd in
    let%lwt () = Lwt_unix.sleep delay in
    answer fd data
  in
  let rec accept_all = function
    | 0 -> Lwt_unix.close sock
    | remaining ->
      let%lwt fd, _ = Lwt_unix.accept sock in
      Lwt.dont_wait (fun () -> respond fd) (fun (_ : exn) -> ());
      accept_all (remaining - 1)
  in
  Lwt.dont_wait (fun () -> accept_all count) (fun (_ : exn) -> ());
  Lwt.return port

let post ?(headers = []) ?(timeouts = Ai_provider.Http_timeouts.default) url =
  Ai_provider.Http_client.post ~timeouts ~provider:"test" ~headers ~body:"{}" url

let expect_network_error ~retryable promise =
  match%lwt promise with
  | _ -> fail "expected a network error"
  | exception Ai_provider.Provider_error.Provider_error { kind = Network_error _; is_retryable; _ } ->
    (check bool) "retryable" retryable is_retryable;
    Lwt.return_unit

let ok_reply = Reply "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"

(* A 1xx block is skipped; the final head carries the status and headers. *)
let test_informational_skipped () =
  let%lwt port, _ =
    serve_once
      (Reply
         "HTTP/1.1 100 Continue\r\n\
          \r\n\
          HTTP/1.1 429 Too Many Requests\r\n\
          Retry-After: 7\r\n\
          Content-Length: 4\r\n\
          \r\n\
          slow")
  in
  let%lwt response = post (Printf.sprintf "http://127.0.0.1:%d/" port) in
  (check int) "final status" 429 (Ai_provider.Http_client.status response);
  (check (option string)) "retry-after" (Some "7") (Ai_provider.Http_client.header response "Retry-After");
  let%lwt body = Ai_provider.Http_client.error_body response in
  (check string) "body" "slow" body;
  Lwt.return_unit

(* A body cut short still yields the part that arrived. *)
let test_error_body_partial () =
  let%lwt port, _ = serve_once (Reply "HTTP/1.1 503 Unavailable\r\nContent-Length: 100\r\n\r\npartial") in
  let%lwt response = post (Printf.sprintf "http://127.0.0.1:%d/" port) in
  let%lwt body = Ai_provider.Http_client.error_body response in
  (check string) "partial body" "partial" body;
  Lwt.return_unit

(* An oversized error body is cut at 64 KiB instead of being buffered whole. *)
let test_error_body_capped () =
  let%lwt port, _ =
    serve_once (Reply ("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 1000000\r\n\r\n" ^ String.make 70000 'x'))
  in
  let%lwt response = post (Printf.sprintf "http://127.0.0.1:%d/" port) in
  let%lwt body = Ai_provider.Http_client.error_body response in
  (check int) "capped length" 65536 (String.length body);
  Lwt.return_unit

(* Parallel requests to an HTTP/1.1 server each open a connection instead of
   queueing behind the first response, which would count against the connect
   timeout. *)
let test_parallel_http1 () =
  let%lwt port = serve_slowly ~count:2 ~delay:0.5 "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" in
  let timeouts = Ai_provider.Http_timeouts.create ~connect_timeout:0.2 () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  let%lwt first = post ~timeouts url
  and second = post ~timeouts url in
  (check (list int)) "both answered" [ 200; 200 ] (List.map Ai_provider.Http_client.status [ first; second ]);
  Lwt.return_unit

let test_default_user_agent () =
  let%lwt port, request = serve_once ok_reply in
  let%lwt (_ : Ai_provider.Http_client.response) = post (Printf.sprintf "http://127.0.0.1:%d/" port) in
  let%lwt head = request in
  (check bool) "sdk user agent" true (contains ~sub:"\r\nUser-Agent: ocaml-ai-sdk/" head);
  Lwt.return_unit

let test_caller_user_agent () =
  let%lwt port, request = serve_once ok_reply in
  let%lwt (_ : Ai_provider.Http_client.response) =
    post ~headers:[ "user-agent", "caller/1.0" ] (Printf.sprintf "http://127.0.0.1:%d/" port)
  in
  let%lwt head = request in
  (check bool) "caller user agent" true (contains ~sub:"\r\nuser-agent: caller/1.0\r\n" head);
  (check bool) "no sdk user agent" false (contains ~sub:"ocaml-ai-sdk/" head);
  Lwt.return_unit

(* CURLE_GOT_NOTHING: the server closed without answering. *)
let test_empty_reply_retryable () =
  let%lwt port, _ = serve_once (Reply "") in
  expect_network_error ~retryable:true (post (Printf.sprintf "http://127.0.0.1:%d/" port))

let test_non_http_scheme_rejected () = expect_network_error ~retryable:false (post "file:///etc/hostname")

(* CURLE_SSL_CONNECT_ERROR: https against a plain-HTTP port is a configuration
   error that a retry cannot fix. *)
let test_tls_to_plain_port_not_retryable () =
  let%lwt port, _ = serve_once (Greet "HTTP/1.1 400 Bad Request\r\n\r\n") in
  expect_network_error ~retryable:false (post (Printf.sprintf "https://127.0.0.1:%d/" port))

(* The connect timeout covers the TLS handshake, well before request_timeout. *)
let test_connect_timeout () =
  let%lwt port, _ = serve_once Hang in
  let timeouts = Ai_provider.Http_timeouts.create ~connect_timeout:0.2 ~request_timeout:30.0 () in
  let started = Unix.gettimeofday () in
  let%lwt () = expect_network_error ~retryable:true (post ~timeouts (Printf.sprintf "https://127.0.0.1:%d/" port)) in
  (check bool) "bounded by connect_timeout" true (Float.compare (Unix.gettimeofday () -. started) 5.0 < 0);
  Lwt.return_unit

(* SSL_CERT_FILE replaces libcurl's CA bundle: a missing file fails the TLS
   setup instead of being ignored. The wording of the error depends on the TLS
   backend, so the test checks that the failure is not retryable and arrives
   well before the connect timeout, which a hung handshake would wait out. *)
let test_ssl_cert_file_honoured () =
  let%lwt port, _ = serve_once Hang in
  let connect_timeout = 5.0 in
  let timeouts = Ai_provider.Http_timeouts.create ~connect_timeout () in
  Unix.putenv "SSL_CERT_FILE" "/nonexistent/ocaml-ai-sdk-test-ca.pem";
  let started = Unix.gettimeofday () in
  Lwt.finalize
    (fun () ->
      let%lwt () =
        expect_network_error ~retryable:false (post ~timeouts (Printf.sprintf "https://127.0.0.1:%d/" port))
      in
      (check bool) "before the connect timeout" true
        (Float.compare (Unix.gettimeofday () -. started) (connect_timeout /. 2.) < 0);
      Lwt.return_unit)
    (fun () ->
      Unix.putenv "SSL_CERT_FILE" "";
      Lwt.return_unit)

(* libcurl rejects a string option over 8 MB. The rejected option surfaces as a
   non-retryable Network_error, not as a Curl.CurlException. *)
let test_rejected_option_not_retryable () =
  expect_network_error ~retryable:false (post ("http://127.0.0.1/" ^ String.make 8_000_000 'a'))

(* A refused CONNECT is retryable only when the proxy's status is. libcurl reads
   the proxy from the environment, so these run last and clear it after. *)
let with_https_proxy port f =
  Unix.putenv "https_proxy" (Printf.sprintf "http://127.0.0.1:%d" port);
  Lwt.finalize f (fun () ->
    Unix.putenv "https_proxy" "";
    Lwt.return_unit)

let test_proxy_refusal ~status ~retryable () =
  let%lwt port, request =
    serve_once (Reply (Printf.sprintf "HTTP/1.1 %d Refused\r\nContent-Length: 0\r\n\r\n" status))
  in
  let%lwt () = with_https_proxy port (fun () -> expect_network_error ~retryable (post "https://provider.invalid/v1")) in
  let%lwt head = request in
  (check bool) "tunnel requested from the proxy" true (contains ~sub:"CONNECT provider.invalid:443 " head);
  Lwt.return_unit

(* Proxy and CA settings come from the environment, and would route, bypass or
   fail the loopback requests depending on the machine. An empty value counts as
   unset. *)
let clear_network_environment () =
  List.iter
    (fun name -> Unix.putenv name "")
    [
      "http_proxy";
      "https_proxy";
      "HTTPS_PROXY";
      "all_proxy";
      "ALL_PROXY";
      "no_proxy";
      "NO_PROXY";
      "SSL_CERT_FILE";
      "SSL_CERT_DIR";
    ]

let () =
  clear_network_environment ();
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
      ( "transfer",
        [
          test_case "1xx head skipped" `Quick (run_lwt test_informational_skipped);
          test_case "partial error body kept" `Quick (run_lwt test_error_body_partial);
          test_case "error body capped" `Quick (run_lwt test_error_body_capped);
          test_case "parallel http/1.1 requests" `Quick (run_lwt test_parallel_http1);
          test_case "default user agent" `Quick (run_lwt test_default_user_agent);
          test_case "caller user agent wins" `Quick (run_lwt test_caller_user_agent);
        ] );
      ( "failure_classification",
        [
          test_case "empty reply retryable" `Quick (run_lwt test_empty_reply_retryable);
          test_case "non-http scheme rejected" `Quick (run_lwt test_non_http_scheme_rejected);
          test_case "tls to plain port not retryable" `Quick (run_lwt test_tls_to_plain_port_not_retryable);
          test_case "connect timeout" `Quick (run_lwt test_connect_timeout);
          test_case "SSL_CERT_FILE honoured" `Quick (run_lwt test_ssl_cert_file_honoured);
          test_case "rejected option not retryable" `Quick (run_lwt test_rejected_option_not_retryable);
        ] );
      ( "proxy",
        [
          test_case "407 not retryable" `Quick (run_lwt (test_proxy_refusal ~status:407 ~retryable:false));
          test_case "503 retryable" `Quick (run_lwt (test_proxy_refusal ~status:503 ~retryable:true));
        ] );
    ]
