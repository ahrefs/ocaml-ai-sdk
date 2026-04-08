type t = {
  push : Ui_message_chunk.t option -> unit;
  in_flight : int ref;
  all_done : unit Lwt.t;
  wake_all_done : unit Lwt.u;
}

let write t chunk = t.push (Some chunk)

let decr_in_flight t =
  t.in_flight := !(t.in_flight) - 1;
  if !(t.in_flight) = 0 then Lwt.wakeup_later t.wake_all_done ()

let merge t stream =
  t.in_flight := !(t.in_flight) + 1;
  (* Lwt.async safety: unbounded push target, try%lwt wraps all errors,
     in_flight counter prevents premature stream close. See .mli for details. *)
  Lwt.async (fun () ->
    try%lwt
      let%lwt () = Lwt_stream.iter (fun chunk -> t.push (Some chunk)) stream in
      decr_in_flight t;
      Lwt.return_unit
    with exn ->
      t.push (Some (Ui_message_chunk.Error { error_text = Printexc.to_string exn }));
      decr_in_flight t;
      Lwt.return_unit)

let create_ui_message_stream ?message_id ?(on_error = Printexc.to_string) ?on_finish ~execute () =
  let stream, push = Lwt_stream.create () in
  let all_done, wake_all_done = Lwt.wait () in
  let writer = { push; in_flight = ref 0; all_done; wake_all_done } in
  push (Some (Ui_message_chunk.Start { message_id; message_metadata = None }));
  (* Lwt.async safety: same rationale as merge — see .mli *)
  Lwt.async (fun () ->
    let%lwt is_aborted =
      try%lwt
        let%lwt () = execute writer in
        let%lwt () = if !(writer.in_flight) > 0 then writer.all_done else Lwt.return_unit in
        Lwt.return_false
      with exn ->
        let error_text = on_error exn in
        push (Some (Ui_message_chunk.Error { error_text }));
        Lwt.return_true
    in
    push (Some (Ui_message_chunk.Finish { finish_reason = None; message_metadata = None }));
    let%lwt () =
      match on_finish with
      | Some f -> (try%lwt f ~finish_reason:None ~is_aborted with _exn -> Lwt.return_unit)
      | None -> Lwt.return_unit
    in
    push None;
    Lwt.return_unit);
  stream

let create_ui_message_stream_response ?(status = `OK) ?(headers = []) ?(cors = true) chunks =
  let sse_stream = Ui_message_stream.stream_to_sse chunks in
  let extra_headers =
    match cors with
    | true -> Server_handler.cors_headers @ headers
    | false -> headers
  in
  Server_handler.make_sse_response ~status ~extra_headers sse_stream
