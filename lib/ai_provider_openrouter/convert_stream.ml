open Melange_json.Primitives

type tool_call_state = {
  id : string;
  name : string;
}

type delta_tool_call_function_json = {
  name : string option; [@json.default None]
  arguments : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type delta_tool_call_json = {
  index : int;
  id : string option; [@json.default None]
  function_ : delta_tool_call_function_json option; [@json.key "function"] [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type delta_json = {
  content : string option; [@json.default None]
  reasoning : string option; [@json.default None]
  tool_calls : delta_tool_call_json list; [@json.default []]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type choice_json = {
  index : int; [@json.default 0]
  delta : delta_json;
  finish_reason : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type chunk_json = {
  choices : choice_json list; [@json.default []]
  usage : Convert_usage.openrouter_usage option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

let empty_usage = { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = None }

let transform events ~warnings =
  let tool_calls : (int, tool_call_state) Hashtbl.t = Hashtbl.create 4 in
  let is_first = ref true in
  let finished = ref false in
  let last_usage = ref None in
  let stream, push = Lwt_stream.create () in
  let emit_start () =
    if !is_first then begin
      push (Some (Ai_provider.Stream_part.Stream_start { warnings }));
      is_first := false
    end
  in
  let finish_open_tool_calls () =
    Hashtbl.iter
      (fun _index (state : tool_call_state) ->
        push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = state.id })))
      tool_calls;
    Hashtbl.clear tool_calls
  in
  Lwt.async (fun () ->
    let%lwt () =
      Lwt_stream.iter
        (fun (evt : Sse.event) ->
          match String.equal evt.data "[DONE]" with
          | true ->
            finish_open_tool_calls ();
            if not !finished then begin
              let usage =
                match !last_usage with
                | Some u -> Convert_usage.to_usage u
                | None -> empty_usage
              in
              push (Some (Ai_provider.Stream_part.Finish { finish_reason = Ai_provider.Finish_reason.Stop; usage }));
              finished := true
            end
          | false ->
          try
            let json = Yojson.Basic.from_string evt.data in
            let chunk = chunk_json_of_json json in
            emit_start ();
            Stdlib.Option.iter (fun u -> last_usage := Some u) chunk.usage;
            match List.nth_opt chunk.choices 0 with
            | None -> ()
            | Some choice ->
              let delta = choice.delta in
              (* Reasoning content *)
              Stdlib.Option.iter
                (fun text -> push (Some (Ai_provider.Stream_part.Reasoning { text })))
                delta.reasoning;
              (* Text content *)
              Stdlib.Option.iter (fun text -> push (Some (Ai_provider.Stream_part.Text { text }))) delta.content;
              (* Tool calls *)
              List.iter
                (fun (tc : delta_tool_call_json) ->
                  Stdlib.Option.iter
                    (fun id ->
                      let name =
                        match tc.function_ with
                        | Some { name = Some n; _ } -> n
                        | Some { name = None; _ } | None -> ""
                      in
                      Hashtbl.replace tool_calls tc.index { id; name })
                    tc.id;
                  match tc.function_ with
                  | Some { arguments = Some args; _ } when String.length args > 0 ->
                    (match Hashtbl.find_opt tool_calls tc.index with
                    | Some { id; name } ->
                      push
                        (Some
                           (Ai_provider.Stream_part.Tool_call_delta
                              {
                                tool_call_type = "function";
                                tool_call_id = id;
                                tool_name = name;
                                args_text_delta = args;
                              }))
                    | None -> ())
                  | Some _ | None -> ())
                delta.tool_calls;
              (* Finish reason *)
              Stdlib.Option.iter
                (fun reason ->
                  finish_open_tool_calls ();
                  let usage =
                    match !last_usage with
                    | Some u -> Convert_usage.to_usage u
                    | None -> empty_usage
                  in
                  push
                    (Some
                       (Ai_provider.Stream_part.Finish
                          { finish_reason = Convert_response.map_finish_reason (Some reason); usage }));
                  finished := true)
                choice.finish_reason
          with (Yojson.Json_error _ | Melange_json.Of_json_error _) as exn ->
            push
              (Some
                 (Ai_provider.Stream_part.Error
                    {
                      error =
                        {
                          Ai_provider.Provider_error.provider = "openrouter";
                          kind = Deserialization_error { message = Printexc.to_string exn; raw = evt.data };
                        };
                    })))
        events
    in
    push None;
    Lwt.return_unit);
  stream
