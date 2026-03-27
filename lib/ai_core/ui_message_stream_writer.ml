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
  (* Lwt.async safety:
     - push target is an unbounded Lwt_stream — pushes never block or fail
     - Lwt.catch ensures exceptions become Error chunks, not unhandled rejections
     - in_flight ref count prevents the output stream from closing while this
       merge is still consuming
     - Same pattern as Ui_message_stream.stream_to_sse, Stream_text.stream_text,
       and provider convert_stream modules throughout this codebase *)
  Lwt.async (fun () ->
    Lwt.catch
      (fun () ->
        let%lwt () = Lwt_stream.iter (fun chunk -> t.push (Some chunk)) stream in
        decr_in_flight t;
        Lwt.return_unit)
      (fun exn ->
        t.push (Some (Ui_message_chunk.Error { error_text = Printexc.to_string exn }));
        decr_in_flight t;
        Lwt.return_unit))

let create_ui_message_stream ?message_id ?(on_error = Printexc.to_string)
    ?on_finish ~execute () =
  let stream, push = Lwt_stream.create () in
  let all_done, wake_all_done = Lwt.wait () in
  let writer = { push; in_flight = ref 0; all_done; wake_all_done } in
  push (Some (Ui_message_chunk.Start { message_id; message_metadata = None }));
  (* Lwt.async safety: same rationale as merge — unbounded stream target,
     Lwt.catch prevents unhandled rejections, stream is closed (push None)
     on all paths so consumers always terminate *)
  Lwt.async (fun () ->
    let%lwt is_aborted =
      Lwt.catch
        (fun () ->
          let%lwt () = execute writer in
          let%lwt () =
            if !(writer.in_flight) > 0 then writer.all_done
            else Lwt.return_unit
          in
          Lwt.return_false)
        (fun exn ->
          let error_text = on_error exn in
          push (Some (Ui_message_chunk.Error { error_text }));
          Lwt.return_true)
    in
    push (Some (Ui_message_chunk.Finish { finish_reason = None; message_metadata = None }));
    let%lwt () =
      match on_finish with
      | Some f ->
        Lwt.catch
          (fun () -> f ~finish_reason:None ~is_aborted)
          (fun _exn -> Lwt.return_unit)
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
