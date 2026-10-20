type t = {
  push : Ui_message_chunk.t -> unit;
  error_text : exn -> string;
  ongoing : unit Lwt.t Queue.t;
  saw_abort : bool ref;
}

let write t chunk =
  (match chunk with
  | Ui_message_chunk.Abort _ -> t.saw_abort := true
  | Start _ | Finish _ | Start_step | Finish_step | Text_start _ | Text_delta _ | Text_end _ | Reasoning_start _
  | Reasoning_delta _ | Reasoning_end _ | Tool_input_start _ | Tool_input_delta _ | Tool_input_available _
  | Tool_output_available _ | Tool_output_error _ | Source_url _ | File _ | Message_metadata _ | Tool_input_error _
  | Tool_output_denied _ | Tool_approval_request _ | Source_document _ | Error _ | Data _ ->
    ());
  t.push chunk

(* The merge promise never fails: [t.push] does not raise, and a failure of
   [stream] becomes an [Error] chunk. *)
let merge t stream =
  let merged =
    try%lwt Lwt_stream.iter (write t) stream
    with exn ->
      t.push (Ui_message_chunk.Error { error_text = t.error_text exn });
      Lwt.return_unit
  in
  Queue.add merged t.ongoing

(* Like upstream's waitForStreams: a merge started while an earlier one runs
   is waited for too. *)
let rec wait_for_ongoing t =
  match Queue.take_opt t.ongoing with
  | None -> Lwt.return_unit
  | Some promise ->
    let%lwt () = promise in
    wait_for_ongoing t

let create_ui_message_stream ?message_id ?(on_error = Printexc.to_string) ?on_finish ~execute () =
  let stream, push = Lwt_stream.create () in
  (* Set once the writer has pushed its last chunk. As upstream's safeEnqueue, a
     chunk that comes later is dropped. *)
  let done_writing = ref false in
  let push_chunk chunk =
    match !done_writing with
    | true -> ()
    | false -> push (Some chunk)
  in
  (* An [on_error] that raises must not leak the exception's text. *)
  let error_text exn =
    match on_error exn with
    | text -> text
    | exception (_ : exn) -> "An error occurred."
  in
  let writer = { push = push_chunk; error_text; ongoing = Queue.create (); saw_abort = ref false } in
  push_chunk (Ui_message_chunk.Start { message_id; message_metadata = None });
  let execute_failed = ref false in
  (* As upstream, a failed [execute] is one more ongoing promise: its [Error]
     chunk goes out at once, and the merges it started still run to the end. *)
  let executed =
    try%lwt execute writer
    with exn ->
      execute_failed := true;
      push_chunk (Ui_message_chunk.Error { error_text = error_text exn });
      Lwt.return_unit
  in
  Queue.add executed writer.ongoing;
  let finish () =
    let%lwt () = wait_for_ongoing writer in
    (* After an [Abort] chunk the writer adds no [Finish] of its own, as
       upstream's does. *)
    (match !(writer.saw_abort) with
    | true -> ()
    | false -> push_chunk (Ui_message_chunk.Finish { finish_reason = None; message_metadata = None }));
    (* A chunk written while [on_finish] runs is dropped. The stream itself
       closes only after [on_finish], as upstream's does. *)
    done_writing := true;
    let is_aborted = !execute_failed || !(writer.saw_abort) in
    match on_finish with
    | Some f -> (try%lwt f ~finish_reason:None ~is_aborted with (_ : exn) -> Lwt.return_unit)
    | None -> Lwt.return_unit
  in
  (* Nothing in [finish] fails, and the stream closes whatever happens. *)
  Lwt.dont_wait
    (fun () ->
      Lwt.finalize finish (fun () ->
        done_writing := true;
        push None;
        Lwt.return_unit))
    (fun (_ : exn) -> ());
  stream

let create_ui_message_stream_response ?(status = 200) ?(headers = []) ?(cors = true) chunks =
  let sse_stream = Ui_message_stream.stream_to_sse chunks in
  let extra_headers =
    match cors with
    | true -> Server_handler.cors_headers @ headers
    | false -> headers
  in
  Server_handler.make_sse_response ~status ~extra_headers sse_stream
