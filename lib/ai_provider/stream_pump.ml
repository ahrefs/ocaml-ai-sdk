let non_retryable ~provider kind = { Provider_error.provider; kind; is_retryable = false; retry_after_s = None }

let pump ?abort_signal ~provider ~push f events =
  let fail error = push (Some (Stream_part.Error { error })) in
  (* A malformed event is reported and skipped; any other failure ends the stream. *)
  let on_event (evt : Sse.event) =
    try f evt
    with
    | ( Yojson.Json_error _ | Yojson.End_of_array | Yojson.End_of_object | Yojson.End_of_input
      | Yojson.Basic.Util.Type_error _ | Yojson.Basic.Util.Undefined _ | Yojson.Safe.Util.Type_error _
      | Yojson.Safe.Util.Undefined _ | Melange_json.Of_json_error _ | Melange_json.Of_string_error _ ) as exn
    ->
      fail (non_retryable ~provider (Deserialization_error { message = Printexc.to_string exn; raw = evt.data }))
  in
  let stream_failed = function
    | Provider_error.Provider_error error -> error
    | exn -> non_retryable ~provider (Unexpected_error { message = Printexc.to_string exn })
  in
  Lwt.dont_wait
    (fun () ->
      let%lwt () = Lwt_stream.iter on_event events in
      push None;
      Lwt.return_unit)
    (fun exn ->
      (* Once the call's signal has fired, its abort or cancel is what the
         caller asked for, so there is nothing to report. Any other is an
         error, as a stray cancel would otherwise look like a normal end. *)
      (match exn, abort_signal with
      | (Abort_signal.Aborted _ | Lwt.Canceled), Some signal when Abort_signal.is_aborted signal -> ()
      | exn, (Some _ | None) -> fail (stream_failed exn));
      push None)
