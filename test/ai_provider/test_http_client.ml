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

(* Loopback server. Each test serves one connection with a canned reply. *)

type reply =
  | Reply of string  (** Written after the request head arrives, then the connection closes. *)
  | Greet of string  (** Written on accept, without reading the request. *)
  | Hang  (** The connection is accepted and never answered. *)
  | Hold of string  (** Written after the request head arrives; the request resolves once the client hangs up. *)

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

(* Reads until the client closes its side. *)
let drain fd =
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match%lwt Lwt_unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Lwt.return_unit
    | _ -> loop ()
  in
  try%lwt loop () with Unix.Unix_error _ -> Lwt.return_unit

(* Half-closes, then drains what the client still sends before closing: closing
   with unread data sends an RST, which can drop the reply before curl reads it. *)
let finish fd =
  Lwt_unix.shutdown fd SHUTDOWN_SEND;
  let%lwt () = drain fd in
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
    | Hold data ->
      let%lwt head = read_head fd in
      let%lwt () = write_all fd data in
      let%lwt () = drain fd in
      let%lwt () = Lwt_unix.close fd in
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

let post ?abort_signal ?(headers = []) ?(timeouts = Ai_provider.Http_timeouts.default) url =
  Ai_provider.Http_client.post ?abort_signal ~timeouts ~provider:"test" ~headers ~body:"{}" url

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

(* A server that accepts and never answers fails the request with the
   non-retryable Request_headers timeout. *)
let test_request_timeout () =
  let%lwt port, _ = serve_once Hang in
  let timeouts = Ai_provider.Http_timeouts.create ~request_timeout:0.3 () in
  match%lwt post ~timeouts (Printf.sprintf "http://127.0.0.1:%d/" port) with
  | _ -> fail "expected a Request_headers timeout"
  | exception
      Ai_provider.Provider_error.Provider_error { kind = Timeout { phase = Request_headers; _ }; is_retryable; _ } ->
    (check bool) "retryable" false is_retryable;
    Lwt.return_unit

(* A body cut short after the headers hands out the lines that arrived, then
   fails the next read with a retryable Network_error. *)
let test_truncated_body_lines () =
  let%lwt port, _ = serve_once (Reply "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\ndata: one\n") in
  let%lwt response = post (Printf.sprintf "http://127.0.0.1:%d/" port) in
  let lines = Ai_provider.Http_client.body_lines response in
  let%lwt first = Lwt_stream.get lines in
  (check (option string)) "first line" (Some "data: one") first;
  expect_network_error ~retryable:true (Lwt.apply Lwt_stream.get lines)

(* Sets an environment variable for the duration of [f]. An empty value counts
   as unset. *)
let with_env name value f =
  Unix.putenv name value;
  Lwt.finalize f (fun () ->
    Unix.putenv name "";
    Lwt.return_unit)

(* A readable SSL_CERT_FILE replaces libcurl's CA bundle: one holding no
   certificate fails the TLS setup. The wording of the error depends on the TLS
   backend, so the test checks that the failure is not retryable and arrives
   well before the connect timeout, which a hung handshake would wait out. *)
let test_ssl_cert_file_honoured () =
  let%lwt port, _ = serve_once Hang in
  let connect_timeout = 5.0 in
  let timeouts = Ai_provider.Http_timeouts.create ~connect_timeout () in
  let ca_file = Filename.temp_file "ocaml-ai-sdk-test-ca" ".pem" in
  let started = Unix.gettimeofday () in
  Lwt.finalize
    (fun () ->
      let%lwt () =
        with_env "SSL_CERT_FILE" ca_file (fun () ->
          expect_network_error ~retryable:false (post ~timeouts (Printf.sprintf "https://127.0.0.1:%d/" port)))
      in
      (check bool) "before the connect timeout" true
        (Float.compare (Unix.gettimeofday () -. started) (connect_timeout /. 2.) < 0);
      Lwt.return_unit)
    (fun () ->
      Sys.remove ca_file;
      Lwt.return_unit)

(* An SSL_CERT_FILE that cannot be read is skipped, as OpenSSL skipped it for
   the cohttp client: the handshake still starts, and the hung server makes it
   wait out the connect timeout. *)
let test_unreadable_ssl_cert_file_skipped () =
  let%lwt port, _ = serve_once Hang in
  let timeouts = Ai_provider.Http_timeouts.create ~connect_timeout:0.2 () in
  with_env "SSL_CERT_FILE" "/nonexistent/ocaml-ai-sdk-test-ca.pem" (fun () ->
    expect_network_error ~retryable:true (post ~timeouts (Printf.sprintf "https://127.0.0.1:%d/" port)))

(* libcurl rejects a string option over 8 MB. The rejected option surfaces as a
   non-retryable Network_error, not as a Curl.CurlException. *)
let test_rejected_option_not_retryable () =
  match%lwt post ("http://127.0.0.1/" ^ String.make 8_000_000 'a') with
  | _ -> fail "expected a network error"
  | exception Ai_provider.Provider_error.Provider_error { kind = Network_error { message }; is_retryable; _ } ->
    (check bool) "retryable" false is_retryable;
    (check bool) "names the code" true (contains ~sub:"(CURLE_BAD_FUNCTION_ARGUMENT)" message);
    Lwt.return_unit

let expect_aborted promise =
  match%lwt promise with
  | _ -> fail "expected Aborted"
  | exception Ai_provider.Abort_signal.Aborted _ -> Lwt.return_unit

(* The server never accepts, so a request that went out would wait for headers
   until request_timeout. *)
let test_abort_before_start () =
  let%lwt sock, port = listen_loopback ~backlog:1 in
  let timeouts = Ai_provider.Http_timeouts.create ~request_timeout:5.0 () in
  let%lwt () =
    expect_aborted (post ~abort_signal:Lwt.return_unit ~timeouts (Printf.sprintf "http://127.0.0.1:%d/" port))
  in
  let%lwt connected =
    Lwt.pick
      [
        (let%lwt (_ : Lwt_unix.file_descr * Unix.sockaddr) = Lwt_unix.accept sock in
         Lwt.return true);
        (let%lwt () = Lwt_unix.sleep 0.2 in
         Lwt.return false);
      ]
  in
  (check bool) "no connection" false connected;
  Lwt_unix.close sock

(* The server reads the request and never answers. The abort fails [post] at
   once, far below request_timeout, and closes the connection. *)
let test_abort_waiting_for_headers () =
  let%lwt port, request = serve_once (Hold "") in
  let signal, abort = Lwt.wait () in
  let timeouts = Ai_provider.Http_timeouts.create ~request_timeout:30.0 () in
  let response = post ~abort_signal:signal ~timeouts (Printf.sprintf "http://127.0.0.1:%d/" port) in
  let%lwt () = Lwt_unix.sleep 0.2 in
  let started = Unix.gettimeofday () in
  Lwt.wakeup_later abort ();
  let%lwt () = expect_aborted response in
  (check bool) "fails promptly" true (Float.compare (Unix.gettimeofday () -. started) 1.0 < 0);
  let%lwt (_ : string) = Lwt_unix.with_timeout 5.0 (fun () -> request) in
  Lwt.return_unit

(* Headers and part of the body arrive, then the server stalls. The abort fails
   the waiting read with Aborted, which [error_body] does not swallow, and
   closes the connection. *)
let test_abort_mid_body ~status read () =
  let%lwt port, request =
    serve_once (Hold (Printf.sprintf "HTTP/1.1 %d Status\r\nContent-Length: 100\r\n\r\npartial" status))
  in
  let signal, abort = Lwt.wait () in
  let timeouts = Ai_provider.Http_timeouts.create ~stream_idle_timeout:30.0 () in
  let%lwt response = post ~abort_signal:signal ~timeouts (Printf.sprintf "http://127.0.0.1:%d/" port) in
  let body = read response in
  let%lwt () = Lwt_unix.sleep 0.2 in
  (check bool) "read waiting for the rest" true (Lwt.is_sleeping body);
  Lwt.wakeup_later abort ();
  let%lwt () = expect_aborted body in
  let%lwt (_ : string) = Lwt_unix.with_timeout 5.0 (fun () -> request) in
  Lwt.return_unit

(* The server sends two SSE events and holds the connection open. *)
let post_sse_then_hold () =
  let%lwt port, request =
    serve_once (Hold "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: one\n\ndata: two\n\n")
  in
  let signal, abort = Lwt.wait () in
  let timeouts = Ai_provider.Http_timeouts.create ~stream_idle_timeout:30.0 () in
  let%lwt response = post ~abort_signal:signal ~timeouts (Printf.sprintf "http://127.0.0.1:%d/" port) in
  Lwt.return (response, abort, request)

let test_abort_mid_lines () =
  let%lwt response, abort, request = post_sse_then_hold () in
  let lines = Ai_provider.Http_client.body_lines response in
  let%lwt received = Lwt_stream.nget 4 lines in
  (check (list string)) "lines before the abort" [ "data: one"; ""; "data: two"; "" ] received;
  let pending = Lwt_stream.get lines in
  (check bool) "read waiting for the next line" true (Lwt.is_sleeping pending);
  Lwt.wakeup_later abort ();
  let%lwt () = expect_aborted (Lwt_unix.with_timeout 5.0 (fun () -> pending)) in
  let%lwt (_ : string) = Lwt_unix.with_timeout 5.0 (fun () -> request) in
  Lwt.return_unit

let describe_part = function
  | Ai_provider.Stream_part.Text { text } -> "text " ^ text
  | Error { error } -> "error " ^ Ai_provider.Provider_error.to_string error
  | _ -> "other"

(* The full provider read path: an abort closes the part stream with no Error part. *)
let test_abort_mid_sse_pump () =
  let%lwt response, abort, request = post_sse_then_hold () in
  let parts, push = Lwt_stream.create () in
  Ai_provider.Stream_pump.pump ~provider:"test" ~push
    (fun evt -> push (Some (Ai_provider.Stream_part.Text { text = evt.data })))
    (Ai_provider.Sse.parse_events (Ai_provider.Http_client.body_lines response));
  let%lwt received = Lwt_stream.nget 2 parts in
  (check (list string)) "parts before the abort" [ "text one"; "text two" ] (List.map describe_part received);
  Lwt.wakeup_later abort ();
  let%lwt rest = Lwt_unix.with_timeout 5.0 (fun () -> Lwt_stream.to_list parts) in
  (check (list string)) "parts after the abort" [] (List.map describe_part rest);
  let%lwt (_ : string) = Lwt_unix.with_timeout 5.0 (fun () -> request) in
  Lwt.return_unit

(* A chunk that arrives just before the abort waits out a pause before it
   reaches the read. The read must still fail. *)
let test_abort_while_chunk_pauses () =
  let chunks, push = Lwt_stream.create () in
  let signal, abort = Lwt.wait () in
  let response =
    Ai_provider.Http_client.For_testing.response_of_chunks ~abort_signal:signal
      ~timeouts:Ai_provider.Http_timeouts.default ~provider:"test" ~status:200 ~headers:[] chunks
  in
  let line = Lwt_stream.get (Ai_provider.Http_client.body_lines response) in
  push (Some "data: late\n");
  Lwt.wakeup_later abort ();
  expect_aborted line

(* The finished transfer has already detached its abort callback, so a later
   abort only changes what reads do: the response keeps its status and a new
   read fails with Aborted. *)
let test_abort_after_completion () =
  let%lwt port, _ = serve_once (Reply "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone") in
  let signal, abort = Lwt.wait () in
  let%lwt response = post ~abort_signal:signal (Printf.sprintf "http://127.0.0.1:%d/" port) in
  let%lwt body = Ai_provider.Http_client.body_string response in
  Lwt.wakeup_later abort ();
  let%lwt () = Lwt.pause () in
  (check string) "body" "done" body;
  (check int) "status" 200 (Ai_provider.Http_client.status response);
  expect_aborted (Ai_provider.Http_client.body_string response)

(* One chunk holds several lines. After the abort, the lines still queued from
   that chunk are not returned. *)
let queued_lines_response () =
  let signal, (_ : unit Lwt.u) = Lwt.task () in
  let response =
    Ai_provider.Http_client.For_testing.response_of_chunks ~abort_signal:signal
      ~timeouts:Ai_provider.Http_timeouts.default ~provider:"test" ~status:200 ~headers:[]
      (Lwt_stream.of_list [ "data: one\n\ndata: two\n\ndata: three\n\n" ])
  in
  response, signal

let test_abort_with_queued_lines () =
  let response, signal = queued_lines_response () in
  let lines = Ai_provider.Http_client.body_lines response in
  let%lwt first = Lwt_stream.get lines in
  (check (option string)) "first line" (Some "data: one") first;
  Lwt.cancel signal;
  expect_aborted (Lwt.apply Lwt_stream.get lines)

let test_abort_with_queued_events () =
  let response, signal = queued_lines_response () in
  let events = Ai_provider.Sse.parse_events (Ai_provider.Http_client.body_lines response) in
  let%lwt first = Lwt_stream.get events in
  (check (option string)) "first event" (Some "one") (Option.map (fun (evt : Ai_provider.Sse.event) -> evt.data) first);
  Lwt.cancel signal;
  expect_aborted (Lwt.apply Lwt_stream.get events)

(* Proxy environment variables are ignored, as cohttp ignored them: the request
   goes straight to the server, never to the proxy, which would answer 502. *)
let test_proxy_environment_ignored () =
  let%lwt proxy_port, _ = serve_once (Reply "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n") in
  let%lwt port, _ = serve_once ok_reply in
  let proxy = Printf.sprintf "http://127.0.0.1:%d" proxy_port in
  let%lwt response =
    with_env "http_proxy" proxy (fun () ->
      with_env "all_proxy" proxy (fun () -> post (Printf.sprintf "http://127.0.0.1:%d/" port)))
  in
  (check int) "served directly" 200 (Ai_provider.Http_client.status response);
  Lwt.return_unit

(* CA settings come from the environment, and would fail the loopback requests
   depending on the machine. An empty value counts as unset. *)
let clear_ca_environment () = List.iter (fun name -> Unix.putenv name "") [ "SSL_CERT_FILE"; "SSL_CERT_DIR" ]

let () =
  clear_ca_environment ();
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
          test_case "request timeout" `Quick (run_lwt test_request_timeout);
          test_case "truncated body lines" `Quick (run_lwt test_truncated_body_lines);
          test_case "SSL_CERT_FILE honoured" `Quick (run_lwt test_ssl_cert_file_honoured);
          test_case "unreadable SSL_CERT_FILE skipped" `Quick (run_lwt test_unreadable_ssl_cert_file_skipped);
          test_case "rejected option not retryable" `Quick (run_lwt test_rejected_option_not_retryable);
        ] );
      ( "abort",
        [
          test_case "already aborted" `Quick (run_lwt test_abort_before_start);
          test_case "while waiting for headers" `Quick (run_lwt test_abort_waiting_for_headers);
          test_case "mid body" `Quick (run_lwt (test_abort_mid_body ~status:200 Ai_provider.Http_client.body_string));
          test_case "mid error body" `Quick
            (run_lwt (test_abort_mid_body ~status:500 Ai_provider.Http_client.error_body));
          test_case "after completion" `Quick (run_lwt test_abort_after_completion);
          test_case "mid body lines" `Quick (run_lwt test_abort_mid_lines);
          test_case "mid SSE stream through pump" `Quick (run_lwt test_abort_mid_sse_pump);
          test_case "chunk waiting out the pause" `Quick (run_lwt test_abort_while_chunk_pauses);
          test_case "lines still queued" `Quick (run_lwt test_abort_with_queued_lines);
          test_case "SSE events still queued" `Quick (run_lwt test_abort_with_queued_events);
        ] );
      "proxy", [ test_case "environment ignored" `Quick (run_lwt test_proxy_environment_ignored) ];
    ]
