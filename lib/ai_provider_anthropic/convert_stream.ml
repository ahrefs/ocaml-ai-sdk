(* Content block tracking state *)
type block_state =
  | Text_block
  | Tool_use_block of {
      id : string;
      name : string;
    }
  | Thinking_block

(* Typed records for SSE event JSON payloads *)

type content_block_info = {
  type_ : string; [@key "type"]
  id : string option; [@default None]
  name : string option; [@default None]
}
[@@deriving of_yojson { strict = false }]

type content_block_start_event = {
  index : int;
  content_block : content_block_info;
}
[@@deriving of_yojson { strict = false }]

type delta_info = {
  type_ : string; [@key "type"]
  text : string option; [@default None]
  partial_json : string option; [@default None]
  thinking : string option; [@default None]
}
[@@deriving of_yojson { strict = false }]

type content_block_delta_event = {
  index : int;
  delta : delta_info;
}
[@@deriving of_yojson { strict = false }]

type content_block_stop_event = { index : int } [@@deriving of_yojson { strict = false }]

type message_delta_info = { stop_reason : string option [@default None] } [@@deriving of_yojson { strict = false }]

type message_delta_event = {
  delta : message_delta_info;
  usage : Convert_usage.anthropic_usage option; [@default None]
}
[@@deriving of_yojson { strict = false }]

type error_info = {
  type_ : string; [@key "type"] [@default "unknown"]
  message : string; [@default ""]
}
[@@deriving of_yojson { strict = false }]

type error_event = { error : error_info } [@@deriving of_yojson { strict = false }]

let transform events ~warnings =
  let blocks : (int, block_state) Hashtbl.t = Hashtbl.create 8 in
  let is_first = ref true in
  let stream, push = Lwt_stream.create () in
  Lwt.async (fun () ->
    let%lwt () =
      Lwt_stream.iter
        (fun (evt : Sse.event) ->
          try
            let json = Yojson.Safe.from_string evt.data in
            match evt.event_type with
            | "message_start" ->
              if !is_first then begin
                push (Some (Ai_provider.Stream_part.Stream_start { warnings }));
                is_first := false
              end
            | "content_block_start" ->
              (match content_block_start_event_of_yojson json with
              | Ok { index; content_block } ->
                (match content_block.type_ with
                | "text" -> Hashtbl.replace blocks index Text_block
                | "tool_use" ->
                  (match content_block.id, content_block.name with
                  | Some id, Some name -> Hashtbl.replace blocks index (Tool_use_block { id; name })
                  | _ -> ())
                | "thinking" -> Hashtbl.replace blocks index Thinking_block
                | _ -> ())
              | Error _ -> ())
            | "content_block_delta" ->
              (match content_block_delta_event_of_yojson json with
              | Ok { index; delta } ->
                (match delta.type_ with
                | "text_delta" ->
                  (match delta.text with
                  | Some text -> push (Some (Ai_provider.Stream_part.Text { text }))
                  | None -> ())
                | "input_json_delta" ->
                  (match delta.partial_json with
                  | Some partial ->
                    (match Hashtbl.find_opt blocks index with
                    | Some (Tool_use_block { id; name }) ->
                      push
                        (Some
                           (Ai_provider.Stream_part.Tool_call_delta
                              {
                                tool_call_type = "function";
                                tool_call_id = id;
                                tool_name = name;
                                args_text_delta = partial;
                              }))
                    | _ -> ())
                  | None -> ())
                | "thinking_delta" ->
                  (match delta.thinking with
                  | Some text -> push (Some (Ai_provider.Stream_part.Reasoning { text }))
                  | None -> ())
                | _ -> ())
              | Error _ -> ())
            | "content_block_stop" ->
              (match content_block_stop_event_of_yojson json with
              | Ok { index } ->
                (match Hashtbl.find_opt blocks index with
                | Some (Tool_use_block { id; _ }) ->
                  push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = id }))
                | _ -> ());
                Hashtbl.remove blocks index
              | Error _ -> ())
            | "message_delta" ->
              (match message_delta_event_of_yojson json with
              | Ok { delta; usage } ->
                let usage =
                  match usage with
                  | Some u -> Convert_usage.to_usage u
                  | None -> { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = None }
                in
                push
                  (Some
                     (Ai_provider.Stream_part.Finish
                        { finish_reason = Convert_response.map_stop_reason delta.stop_reason; usage }))
              | Error _ -> ())
            | "message_stop" | "ping" -> ()
            | "error" ->
              let error_type, message =
                match error_event_of_yojson json with
                | Ok { error = { type_; message } } -> type_, message
                | Error _ -> "unknown", evt.data
              in
              push
                (Some
                   (Ai_provider.Stream_part.Error
                      {
                        error =
                          {
                            Ai_provider.Provider_error.provider = "anthropic";
                            kind = Api_error { status = 0; body = Printf.sprintf "%s: %s" error_type message };
                          };
                      }))
            | _ -> ()
          with Yojson.Json_error _ as exn ->
            push
              (Some
                 (Ai_provider.Stream_part.Error
                    {
                      error =
                        {
                          Ai_provider.Provider_error.provider = "anthropic";
                          kind = Deserialization_error { message = Printexc.to_string exn; raw = evt.data };
                        };
                    })))
        events
    in
    push None;
    Lwt.return_unit);
  stream
