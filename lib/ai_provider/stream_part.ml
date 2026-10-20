type t =
  | Stream_start of { warnings : Warning.t list }
  | Text of { text : string }
  | Reasoning of {
      text : string;
      signature : string option;
      provider_options : Provider_options.t;
    }
  | Tool_call_delta of {
      tool_call_type : string;
      tool_call_id : string;
      tool_name : string;
      args_text_delta : string;
    }
  | Tool_call_finish of { tool_call_id : string }
  | File of {
      data : bytes;
      media_type : string;
    }
  | Source of {
      source_type : string;
      id : string;
      url : string;
      title : string option;
      provider_options : Provider_options.t;
    }
  | Finish of {
      finish_reason : Finish_reason.t;
      usage : Usage.t;
      provider_metadata : Provider_options.t option;
    }
  | Error of { error : Provider_error.t }

let deserialization_error ~provider ~raw exn =
  {
    Provider_error.provider;
    kind = Deserialization_error { message = Printexc.to_string exn; raw };
    is_retryable = false;
    retry_after_s = None;
  }

let pump ~provider ~push f events =
  let fail error = push (Some (Error { error })) in
  (* A malformed event is reported and skipped; any other failure ends the stream. *)
  let on_event (evt : Sse.event) =
    try f evt
    with (Yojson.Json_error _ | Melange_json.Of_json_error _) as exn ->
      fail (deserialization_error ~provider ~raw:evt.data exn)
  in
  Lwt.async (fun () ->
    Lwt.finalize
      (fun () ->
        try%lwt Lwt_stream.iter on_event events with
        | Provider_error.Provider_error error ->
          fail error;
          Lwt.return_unit
        | exn ->
          fail (deserialization_error ~provider ~raw:"" exn);
          Lwt.return_unit)
      (fun () ->
        push None;
        Lwt.return_unit))
