type t = {
  text_stream : string Lwt_stream.t;
  full_stream : Text_stream_part.t Lwt_stream.t;
  partial_output_stream : Yojson.Basic.t Lwt_stream.t;
  usage : Ai_provider.Usage.t Lwt.t;
  finish_reason : Ai_provider.Finish_reason.t Lwt.t;
  steps : Generate_text_result.step list Lwt.t;
  warnings : Ai_provider.Warning.t list;
  output : Yojson.Basic.t option Lwt.t;
}

let to_ui_message_stream ?(message_id : string option) ?(send_reasoning = true) (result : t) =
  let ui_stream, push = Lwt_stream.create () in
  Lwt.async (fun () ->
    push (Some (Ui_message_chunk.Start { message_id; message_metadata = None }));
    (* Track which tool calls have had Tool_input_start emitted *)
    let started_tools : (string, string) Hashtbl.t = Hashtbl.create 4 in
    let%lwt () =
      Lwt_stream.iter
        (fun (part : Text_stream_part.t) ->
          match part with
          | Start -> ()
          | Start_step -> push (Some Ui_message_chunk.Start_step)
          | Text_start { id } -> push (Some (Ui_message_chunk.Text_start { id }))
          | Text_delta { id; text } -> push (Some (Ui_message_chunk.Text_delta { id; delta = text }))
          | Text_end { id } -> push (Some (Ui_message_chunk.Text_end { id }))
          | Reasoning_start { id } -> if send_reasoning then push (Some (Ui_message_chunk.Reasoning_start { id }))
          | Reasoning_delta { id; text } ->
            if send_reasoning then push (Some (Ui_message_chunk.Reasoning_delta { id; delta = text }))
          | Reasoning_end { id } -> if send_reasoning then push (Some (Ui_message_chunk.Reasoning_end { id }))
          | Tool_call_delta { tool_call_id; tool_name; args_text_delta } ->
            (* Emit Tool_input_start on first delta for this tool call *)
            if not (Hashtbl.mem started_tools tool_call_id) then begin
              Hashtbl.replace started_tools tool_call_id tool_name;
              push (Some (Ui_message_chunk.Tool_input_start { tool_call_id; tool_name }))
            end;
            push (Some (Ui_message_chunk.Tool_input_delta { tool_call_id; input_text_delta = args_text_delta }))
          | Tool_call { tool_call_id; tool_name; args } ->
            (* Emit Tool_input_start if not already sent (e.g., no deltas preceded) *)
            if not (Hashtbl.mem started_tools tool_call_id) then begin
              Hashtbl.replace started_tools tool_call_id tool_name;
              push (Some (Ui_message_chunk.Tool_input_start { tool_call_id; tool_name }))
            end;
            Hashtbl.remove started_tools tool_call_id;
            push (Some (Ui_message_chunk.Tool_input_available { tool_call_id; tool_name; input = args }))
          | Tool_result { tool_call_id; result; is_error; tool_name = _ } ->
            if is_error then
              push
                (Some (Ui_message_chunk.Tool_output_error { tool_call_id; error_text = Yojson.Basic.to_string result }))
            else push (Some (Ui_message_chunk.Tool_output_available { tool_call_id; output = result }))
          | Tool_approval_request { approval_id; tool_call_id; tool_name; args } ->
            if not (Hashtbl.mem started_tools tool_call_id) then begin
              Hashtbl.replace started_tools tool_call_id tool_name;
              push (Some (Ui_message_chunk.Tool_input_start { tool_call_id; tool_name }))
            end;
            push (Some (Ui_message_chunk.Tool_input_available { tool_call_id; tool_name; input = args }));
            Hashtbl.remove started_tools tool_call_id;
            push (Some (Ui_message_chunk.Tool_approval_request { approval_id; tool_call_id }))
          | Source { source_id; url; title } -> push (Some (Ui_message_chunk.Source_url { source_id; url; title }))
          | File { url; media_type } -> push (Some (Ui_message_chunk.File { url; media_type }))
          | Finish_step _ -> push (Some Ui_message_chunk.Finish_step)
          | Finish { finish_reason; usage = _ } ->
            push (Some (Ui_message_chunk.Finish { finish_reason = Some finish_reason; message_metadata = None }))
          | Error { error } -> push (Some (Ui_message_chunk.Error { error_text = error })))
        result.full_stream
    in
    push None;
    Lwt.return_unit);
  ui_stream

let to_ui_message_sse_stream ?message_id ?send_reasoning result =
  let ui_stream = to_ui_message_stream ?message_id ?send_reasoning result in
  Ui_message_stream.stream_to_sse ui_stream
