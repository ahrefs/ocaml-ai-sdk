open Alcotest

let run_lwt f () = Lwt_main.run (f ())

(* ---------- in-process TCP server helpers ---------- *)

(* Starts a TCP server on 127.0.0.1:<random port>. Returns the port and a
   stop function. The handler receives each new client socket and decides
   what to do with it. *)
let start_server ~handler =
  let listen_sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt listen_sock Unix.SO_REUSEADDR true;
  let%lwt () = Lwt_unix.bind listen_sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) in
  Lwt_unix.listen listen_sock 16;
  let port =
    match Lwt_unix.getsockname listen_sock with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "not INET"
  in
  let stopped = ref false in
  Lwt.async (fun () ->
    try%lwt
      let rec accept_loop () =
        if !stopped then Lwt.return_unit
        else (
          let%lwt sock, _ = Lwt_unix.accept listen_sock in
          Lwt.async (fun () -> try%lwt handler sock with _ -> Lwt.return_unit);
          accept_loop ())
      in
      accept_loop ()
    with _ -> Lwt.return_unit);
  let stop () =
    stopped := true;
    try%lwt Lwt_unix.close listen_sock with _ -> Lwt.return_unit
  in
  Lwt.return (port, stop)

(* Read the HTTP request from [sock] until the headers terminator (blank line)
   then discard. Accumulates across reads so the terminator can straddle a
   read boundary. *)
let consume_request sock =
  let read_buf = Bytes.create 4096 in
  let accum = Buffer.create 512 in
  let rec loop () =
    let%lwt n = Lwt_unix.read sock read_buf 0 (Bytes.length read_buf) in
    if n = 0 then Lwt.return_unit
    else begin
      Buffer.add_subbytes accum read_buf 0 n;
      let contents = Buffer.contents accum in
      let rec scan i =
        i + 4 <= String.length contents && (String.equal (String.sub contents i 4) "\r\n\r\n" || scan (i + 1))
      in
      if scan 0 then Lwt.return_unit else loop ()
    end
  in
  loop ()

let write_all sock s =
  let b = Bytes.of_string s in
  let len = Bytes.length b in
  let rec loop ofs =
    if ofs >= len then Lwt.return_unit
    else (
      let%lwt n = Lwt_unix.write sock b ofs (len - ofs) in
      loop (ofs + n))
  in
  loop 0

let uri_for port path = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path)

let post_empty ~timeouts ~provider ~port ~path =
  let headers = Cohttp.Header.of_list [ "content-type", "application/json" ] in
  let body = Cohttp_lwt.Body.of_string "{}" in
  Ai_provider.Http_client.post ~timeouts ~provider ~headers ~body (uri_for port path)

(* ---------- tests ---------- *)

(* T2 — request_timeout fires when server accepts TCP but never responds. *)
let test_request_timeout_fires () =
  let%lwt port, stop =
    start_server ~handler:(fun sock ->
      let%lwt () = Lwt_unix.sleep 30.0 in
      Lwt_unix.close sock)
  in
  let timeouts = Ai_provider.Http_timeouts.create ~request_timeout:0.2 () in
  let%lwt result =
    try%lwt
      let%lwt _ = post_empty ~timeouts ~provider:"test" ~port ~path:"/" in
      Lwt.return `No_raise
    with
    | Ai_provider.Provider_error.Provider_error { kind = Timeout { phase = Request_headers; _ }; _ } ->
      Lwt.return `Got_timeout
    | e -> Lwt.return (`Other e)
  in
  let%lwt () = stop () in
  (match result with
  | `Got_timeout -> ()
  | `No_raise -> fail "expected timeout, got success"
  | `Other e -> fail (Printf.sprintf "expected Request_headers timeout, got: %s" (Printexc.to_string e)));
  Lwt.return_unit

(* T3 — request_timeout does NOT fire on a fast response. *)
let test_request_completes_fast () =
  let%lwt port, stop =
    start_server ~handler:(fun sock ->
      let%lwt () = consume_request sock in
      let body = "hello" in
      let resp =
        Printf.sprintf
          "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n%s"
          (String.length body) body
      in
      let%lwt () = write_all sock resp in
      Lwt_unix.close sock)
  in
  let timeouts = Ai_provider.Http_timeouts.create ~request_timeout:5.0 () in
  let%lwt resp, body = post_empty ~timeouts ~provider:"test" ~port ~path:"/" in
  let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
  (check int) "200" 200 status;
  let%lwt body_str = Cohttp_lwt.Body.to_string body in
  (check string) "body" "hello" body_str;
  let%lwt () = stop () in
  Lwt.return_unit

(* T4 — stream_idle_timeout fires when server goes silent mid-stream. *)
let test_stream_idle_fires () =
  let%lwt port, stop =
    start_server ~handler:(fun sock ->
      let%lwt () = consume_request sock in
      let preamble =
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
      in
      let%lwt () = write_all sock preamble in
      let chunk = "data: first\n" in
      let chunked = Printf.sprintf "%x\r\n%s\r\n" (String.length chunk) chunk in
      let%lwt () = write_all sock chunked in
      let%lwt () = Lwt_unix.sleep 30.0 in
      Lwt_unix.close sock)
  in
  let timeouts = Ai_provider.Http_timeouts.create ~request_timeout:5.0 ~stream_idle_timeout:0.2 () in
  let%lwt _resp, body = post_empty ~timeouts ~provider:"test" ~port ~path:"/" in
  let lines = Ai_provider.Http_client.wrap_body_with_idle_timeout ~timeouts ~provider:"test" body in
  let%lwt first = Lwt_stream.get lines in
  (check (option string)) "first line" (Some "data: first") first;
  let%lwt next = Lwt_stream.get lines in
  (check (option string)) "end of stream after idle" None next;
  let%lwt () = stop () in
  Lwt.return_unit

(* T5 — stream_idle_timeout resets on each chunk. *)
let test_stream_idle_resets () =
  let%lwt port, stop =
    start_server ~handler:(fun sock ->
      let%lwt () = consume_request sock in
      let preamble =
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
      in
      let%lwt () = write_all sock preamble in
      let send_chunk s =
        let c = Printf.sprintf "%x\r\n%s\r\n" (String.length s) s in
        write_all sock c
      in
      let rec loop = function
        | 0 ->
          let%lwt () = write_all sock "0\r\n\r\n" in
          Lwt_unix.close sock
        | n ->
          let%lwt () = send_chunk (Printf.sprintf "data: %d\n" n) in
          let%lwt () = Lwt_unix.sleep 0.1 in
          loop (n - 1)
      in
      loop 5)
  in
  let timeouts = Ai_provider.Http_timeouts.create ~request_timeout:5.0 ~stream_idle_timeout:0.3 () in
  let%lwt _resp, body = post_empty ~timeouts ~provider:"test" ~port ~path:"/" in
  let lines = Ai_provider.Http_client.wrap_body_with_idle_timeout ~timeouts ~provider:"test" body in
  let%lwt all = Lwt_stream.to_list lines in
  (check int) "five lines" 5 (List.length all);
  let%lwt () = stop () in
  Lwt.return_unit

let () =
  (* Install-and-forget: the library re-raises timeout errors to
     Lwt.async_exception_hook (which would otherwise exit the process). This
     binary runs only these tests, so a global override is fine — no restore
     needed. In a shared test library this would need save/restore. *)
  (Lwt.async_exception_hook := fun _ -> ());
  run "Http_client"
    [
      ( "timeouts",
        [
          test_case "request_timeout fires" `Quick (run_lwt test_request_timeout_fires);
          test_case "fast request completes" `Quick (run_lwt test_request_completes_fast);
          test_case "stream idle fires" `Quick (run_lwt test_stream_idle_fires);
          test_case "stream idle resets on each chunk" `Quick (run_lwt test_stream_idle_resets);
        ] );
    ]
