open Melange_json.Primitives

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
  type_ : string; [@json.key "type"]
  id : string option; [@json.default None]
  name : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type content_block_start_event = {
  index : int;
  content_block : content_block_info;
}
[@@json.allow_extra_fields] [@@deriving of_json]

type delta_info = {
  type_ : string; [@json.key "type"]
  text : string option; [@json.default None]
  partial_json : string option; [@json.default None]
  thinking : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type content_block_delta_event = {
  index : int;
  delta : delta_info;
}
[@@json.allow_extra_fields] [@@deriving of_json]

type content_block_stop_event = { index : int } [@@json.allow_extra_fields] [@@deriving of_json]

type message_delta_info = { stop_reason : string option [@json.default None] }
[@@json.allow_extra_fields] [@@deriving of_json]

type message_delta_event = {
  delta : message_delta_info;
  usage : Convert_usage.anthropic_usage option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type error_info = {
  type_ : string; [@json.key "type"] [@json.default "unknown"]
  message : string; [@json.default ""]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type error_event = { error : error_info } [@@json.allow_extra_fields] [@@deriving of_json]

let transform events ~warnings =
  let blocks : (int, block_state) Hashtbl.t = Hashtbl.create 8 in
  let is_first = ref true in
  let stream, push = Lwt_stream.create () in
  Lwt.async (fun () ->
    let%lwt () =
      Lwt_stream.iter
        (fun (evt : Sse.event) ->
          try
            let json = Yojson.Basic.from_string evt.data in
            match evt.event_type with
            | "message_start" ->
              if !is_first then begin
                push (Some (Ai_provider.Stream_part.Stream_start { warnings }));
                is_first := false
              end
            | "content_block_start" ->
              let { index; content_block } = content_block_start_event_of_json json in
              (match content_block.type_ with
              | "text" -> Hashtbl.replace blocks index Text_block
              | "tool_use" ->
                (match content_block.id, content_block.name with
                | Some id, Some name -> Hashtbl.replace blocks index (Tool_use_block { id; name })
                | _ -> ())
              | "thinking" -> Hashtbl.replace blocks index Thinking_block
              | _ -> ())
            | "content_block_delta" ->
              let { index; delta } = content_block_delta_event_of_json json in
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
            | "content_block_stop" ->
              let { index } = content_block_stop_event_of_json json in
              (match Hashtbl.find_opt blocks index with
              | Some (Tool_use_block { id; _ }) ->
                push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = id }))
              | _ -> ());
              Hashtbl.remove blocks index
            | "message_delta" ->
              let { delta; usage } = message_delta_event_of_json json in
              let usage =
                match usage with
                | Some u -> Convert_usage.to_usage u
                | None -> { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = None }
              in
              push
                (Some
                   (Ai_provider.Stream_part.Finish
                      { finish_reason = Convert_response.map_stop_reason delta.stop_reason; usage }))
            | "message_stop" | "ping" -> ()
            | "error" ->
              let error_type, message =
                try
                  let { error = { type_; message } } = error_event_of_json json in
                  type_, message
                with Melange_json.Of_json_error _ -> "unknown", evt.data
              in
              push
                (Some
                   (Ai_provider.Stream_part.Error
                      {
                        error =
                          Ai_provider.Provider_error.make_api_error ~provider:"anthropic" ~status:0
                            ~body:(Printf.sprintf "%s: %s" error_type message)
                            ~is_retryable:false ();
                      }))
            | _ -> ()
          with (Yojson.Json_error _ | Melange_json.Of_json_error _) as exn ->
            push
              (Some
                 (Ai_provider.Stream_part.Error
                    {
                      error =
                        {
                          Ai_provider.Provider_error.provider = "anthropic";
                          kind = Deserialization_error { message = Printexc.to_string exn; raw = evt.data };
                          is_retryable = false;
                        };
                    })))
        events
    in
    push None;
    Lwt.return_unit);
  stream
