let post ~(timeouts : Http_timeouts.t) ~provider ~headers ~body uri =
  let started = Unix.gettimeofday () in
  Lwt.catch
    (fun () ->
      Lwt_unix.with_timeout timeouts.request_timeout (fun () ->
        Cohttp_lwt_unix.Client.post ~headers ~body uri))
    (function
      | Lwt_unix.Timeout ->
        let elapsed = Unix.gettimeofday () -. started in
        let err =
          Provider_error.make_timeout
            ~provider
            ~phase:Request_headers
            ~elapsed_s:elapsed
            ~limit_s:timeouts.request_timeout
        in
        Lwt.fail (Provider_error.Provider_error err)
      | exn -> Lwt.fail exn)

let split_on_newlines buf chunk push =
  String.iter
    (function
      | '\n' ->
        push (Some (Buffer.contents buf));
        Buffer.clear buf
      | '\r' -> ()
      | c -> Buffer.add_char buf c)
    chunk

let wrap_body_with_idle_timeout ~(timeouts : Http_timeouts.t) ~provider body =
  let raw = Cohttp_lwt.Body.to_stream body in
  let buf = Buffer.create 256 in
  let out, push = Lwt_stream.create () in
  let drain_upstream () =
    Lwt.catch (fun () -> Cohttp_lwt.Body.drain_body body) (fun _ -> Lwt.return_unit)
  in
  Lwt.async (fun () ->
    Lwt.catch
      (fun () ->
        (* Safe to race Lwt_stream.get against a timeout: cohttp's body feed
           uses Lwt.protected, so Lwt.pick's cancellation can't corrupt the
           stream state. *)
        let rec loop () =
          match%lwt
            Lwt.pick
              [
                (let%lwt c = Lwt_stream.get raw in
                 Lwt.return (`Chunk c));
                (let%lwt () = Lwt_unix.sleep timeouts.stream_idle_timeout in
                 Lwt.return `Idle);
              ]
          with
          | `Chunk None -> Lwt.return_unit
          | `Chunk (Some chunk) ->
            split_on_newlines buf chunk push;
            loop ()
          | `Idle ->
            let err =
              Provider_error.make_timeout
                ~provider
                ~phase:Stream_idle
                ~elapsed_s:timeouts.stream_idle_timeout
                ~limit_s:timeouts.stream_idle_timeout
            in
            Lwt.fail (Provider_error.Provider_error err)
        in
        let%lwt () = loop () in
        if Buffer.length buf > 0 then push (Some (Buffer.contents buf));
        push None;
        Lwt.return_unit)
      (fun exn ->
        push None;
        let%lwt () = drain_upstream () in
        Lwt.fail exn));
  out
