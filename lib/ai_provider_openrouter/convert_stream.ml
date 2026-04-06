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
  reasoning_details : Convert_response.reasoning_detail_json list; [@json.default []]
  tool_calls : delta_tool_call_json list; [@json.default []]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type choice_json = {
  index : int; [@json.default 0]
  delta : delta_json;
  finish_reason : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

(* id, model, provider are present in the wire format but unused during streaming;
   they are consumed by the non-streaming Convert_response path instead. *)
type chunk_json = {
  id : string option; [@json.default None]
  model : string option; [@json.default None]
  provider : string option; [@json.default None]
  choices : choice_json list; [@json.default []]
  usage : Convert_usage.openrouter_usage option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

let empty_usage = { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = None }

(** Extract an error message from a streaming error chunk and emit error + finish. *)
let process_error_chunk ~push ~emit_finish fields =
  let error_json = List.assoc "error" fields in
  let msg =
    match error_json with
    | `Assoc ef ->
      (match List.assoc_opt "message" ef with
      | Some (`String m) -> m
      | _ -> "Unknown streaming error")
    | _ -> "Unknown streaming error"
  in
  push
    (Some
       (Ai_provider.Stream_part.Error
          {
            error =
              {
                Ai_provider.Provider_error.provider = "openrouter";
                kind = Api_error { status = 200; body = msg };
              };
          }));
  emit_finish Ai_provider.Finish_reason.Error

(** Emit reasoning stream parts from structured reasoning_details with legacy fallback. *)
let process_reasoning_deltas ~push ~has_encrypted_reasoning (delta : delta_json) =
  match delta.reasoning_details with
  | _ :: _ as details ->
    List.iter
      (fun (d : Convert_response.reasoning_detail_json) ->
        match d.type_ with
        | "reasoning.text" ->
          Stdlib.Option.iter
            (fun text -> push (Some (Ai_provider.Stream_part.Reasoning { text })))
            d.text
        | "reasoning.encrypted" ->
          (match d.data with
          | Some data when String.length data > 0 ->
            has_encrypted_reasoning := true;
            push (Some (Ai_provider.Stream_part.Reasoning { text = "[REDACTED]" }))
          | Some _ | None -> ())
        | "reasoning.summary" ->
          Stdlib.Option.iter
            (fun summary -> push (Some (Ai_provider.Stream_part.Reasoning { text = summary })))
            d.summary
        | _ -> ())
      details
  | [] ->
    (* Fallback to legacy reasoning *)
    Stdlib.Option.iter
      (fun text -> push (Some (Ai_provider.Stream_part.Reasoning { text })))
      delta.reasoning

(** Process a single tool call delta: register new tool calls and emit argument deltas. *)
let process_tool_call_delta ~push ~has_tool_calls ~tool_calls (tc : delta_tool_call_json) =
  Stdlib.Option.iter
    (fun id ->
      has_tool_calls := true;
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
  | Some _ | None -> ()

let transform events ~warnings =
  let tool_calls : (int, tool_call_state) Hashtbl.t = Hashtbl.create 4 in
  let is_first = ref true in
  let finished = ref false in
  let last_usage = ref None in
  let last_finish_reason = ref None in
  let has_tool_calls = ref false in
  let has_encrypted_reasoning = ref false in
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
  let apply_finish_overrides (fr : Ai_provider.Finish_reason.t) =
    match !has_tool_calls, !has_encrypted_reasoning, fr with
    | true, true, Stop -> Ai_provider.Finish_reason.Tool_calls
    | true, _, Other _ -> Ai_provider.Finish_reason.Tool_calls
    | _ -> fr
  in
  let emit_finish reason =
    if not !finished then begin
      let usage =
        match !last_usage with
        | Some u -> Convert_usage.to_usage u
        | None -> empty_usage
      in
      let final_reason = apply_finish_overrides reason in
      push (Some (Ai_provider.Stream_part.Finish { finish_reason = final_reason; usage }));
      finished := true
    end
  in
  Lwt.async (fun () ->
    let%lwt () =
      Lwt_stream.iter
        (fun (evt : Sse.event) ->
          match String.equal evt.data "[DONE]" with
          | true ->
            finish_open_tool_calls ();
            let reason =
              match !last_finish_reason with
              | Some r -> r
              | None -> Ai_provider.Finish_reason.Stop
            in
            emit_finish reason
          | false ->
          (try
             let json = Yojson.Basic.from_string evt.data in
             match json with
             | `Assoc fields when List.mem_assoc "error" fields ->
               process_error_chunk ~push ~emit_finish fields
             | _ ->
               let chunk = chunk_json_of_json json in
               emit_start ();
               Stdlib.Option.iter (fun u -> last_usage := Some u) chunk.usage;
               (match List.nth_opt chunk.choices 0 with
               | None -> ()
               | Some choice ->
                 let delta = choice.delta in
                 process_reasoning_deltas ~push ~has_encrypted_reasoning delta;
                 (* Text content *)
                 Stdlib.Option.iter
                   (fun text -> push (Some (Ai_provider.Stream_part.Text { text })))
                   delta.content;
                 (* Tool calls *)
                 List.iter
                   (process_tool_call_delta ~push ~has_tool_calls ~tool_calls)
                   delta.tool_calls;
                 (* Finish reason -- store and emit *)
                 Stdlib.Option.iter
                   (fun reason ->
                     let mapped = Convert_response.map_finish_reason (Some reason) in
                     last_finish_reason := Some mapped;
                     finish_open_tool_calls ();
                     emit_finish mapped)
                   choice.finish_reason)
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
                     }))))
        events
    in
    push None;
    Lwt.return_unit);
  stream
