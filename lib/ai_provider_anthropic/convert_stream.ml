(* Content block tracking state *)
type block_state =
  | Text_block
  | Tool_use_block of {
      id : string;
      name : string;
    }
  | Thinking_block

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
            let open Yojson.Safe.Util in
            match evt.event_type with
            | "message_start" ->
              if !is_first then begin
                push (Some (Ai_provider.Stream_part.Stream_start { warnings }));
                is_first := false
              end
            | "content_block_start" ->
              let index = member "index" json |> to_int in
              let block = member "content_block" json in
              let block_type = member "type" block |> to_string in
              (match block_type with
              | "text" -> Hashtbl.replace blocks index Text_block
              | "tool_use" ->
                let id = member "id" block |> to_string in
                let name = member "name" block |> to_string in
                Hashtbl.replace blocks index (Tool_use_block { id; name })
              | "thinking" -> Hashtbl.replace blocks index Thinking_block
              | _ -> ())
            | "content_block_delta" ->
              let index = member "index" json |> to_int in
              let delta = member "delta" json in
              let delta_type = member "type" delta |> to_string in
              (match delta_type with
              | "text_delta" ->
                let text = member "text" delta |> to_string in
                push (Some (Ai_provider.Stream_part.Text { text }))
              | "input_json_delta" ->
                let partial = member "partial_json" delta |> to_string in
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
              | "thinking_delta" ->
                let text = member "thinking" delta |> to_string in
                push (Some (Ai_provider.Stream_part.Reasoning { text }))
              | _ -> ())
            | "content_block_stop" ->
              let index = member "index" json |> to_int in
              (match Hashtbl.find_opt blocks index with
              | Some (Tool_use_block { id; _ }) ->
                push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = id }))
              | _ -> ());
              Hashtbl.remove blocks index
            | "message_delta" ->
              let delta = member "delta" json in
              let stop_reason = try Some (member "stop_reason" delta |> to_string) with Type_error _ -> None in
              let usage_json = try Some (member "usage" json) with Type_error _ -> None in
              let usage =
                match usage_json with
                | Some u -> Convert_usage.to_usage (Convert_usage.anthropic_usage_of_yojson u)
                | None -> { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = None }
              in
              push
                (Some
                   (Ai_provider.Stream_part.Finish
                      { finish_reason = Convert_response.map_stop_reason stop_reason; usage }))
            | "message_stop" | "ping" -> ()
            | "error" ->
              let error_obj = try member "error" json with Type_error _ -> json in
              let error_type = try member "type" error_obj |> to_string with Type_error _ -> "unknown" in
              let message = try member "message" error_obj |> to_string with Type_error _ -> evt.data in
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
          with exn ->
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
