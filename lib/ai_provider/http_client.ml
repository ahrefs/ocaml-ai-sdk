let post ~timeouts ~provider ~headers ~body uri =
  let timeouts : Http_timeouts.t = timeouts in
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

(* Split [chunk] on LF, appending to [buf] and pushing completed lines
   to [push]. CR is stripped. *)
let split_on_newlines buf chunk push =
  let len = String.length chunk in
  let i = ref 0 in
  while !i < len do
    let c = String.get chunk !i in
    (match c with
    | '\n' ->
      push (Some (Buffer.contents buf));
      Buffer.clear buf
    | '\r' -> ()
    | c -> Buffer.add_char buf c);
    incr i
  done

let wrap_body_with_idle_timeout ~timeouts ~provider body =
  let timeouts : Http_timeouts.t = timeouts in
  let raw = Cohttp_lwt.Body.to_stream body in
  let buf = Buffer.create 256 in
  let out, push = Lwt_stream.create () in
  Lwt.async (fun () ->
    Lwt.catch
      (fun () ->
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
        (* Always close the consumer stream so no one hangs, then re-raise
           to Lwt.async_exception_hook so the failure remains visible. *)
        push None;
        Lwt.fail exn));
  out
