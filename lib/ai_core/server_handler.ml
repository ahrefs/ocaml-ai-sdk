open Melange_json.Primitives

let empty_opts = Ai_provider.Provider_options.empty

(** Roles in v6 UIMessage format. *)
type role =
  | System
  | User
  | Assistant

let role_of_string = function
  | "system" -> Some System
  | "user" -> Some User
  | "assistant" -> Some Assistant
  | _ -> None

(** Part types in v6 UIMessage format. *)
type part_type =
  | Text
  | File
  | Reasoning
  | Step_start
  | Source
  | Tool_invocation of string  (** the full type string, e.g. "tool-weather" or "dynamic-tool" *)

let part_type_of_string s =
  match s with
  | "text" -> Text
  | "file" -> File
  | "reasoning" -> Reasoning
  | "step-start" -> Step_start
  | "source" -> Source
  | s when String.starts_with ~prefix:"tool-" s -> Tool_invocation s
  | "dynamic-tool" -> Tool_invocation s
  | _ -> Source (* unknown types are skipped like source *)

(** Tool invocation states in v6 UIMessage format. *)
type tool_state =
  | Input_streaming
  | Input_available
  | Output_available
  | Output_error
  | Output_denied
  | Approval_requested
  | Approval_responded
  | Unknown_state

let tool_state_of_string = function
  | "input-streaming" -> Input_streaming
  | "input-available" -> Input_available
  | "output-available" -> Output_available
  | "output-error" -> Output_error
  | "output-denied" -> Output_denied
  | "approval-requested" -> Approval_requested
  | "approval-responded" -> Approval_responded
  | _ -> Unknown_state

(** A parsed v6 UIMessage part. Derived from JSON via melange-json PPX. *)
type parsed_approval = {
  id : string option; [@json.option]
  approved : bool option; [@json.option]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type parsed_part = {
  type_ : string; [@json.key "type"]
  text : string option; [@json.option]
  media_type : string option; [@json.key "mediaType"] [@json.option]
  url : string option; [@json.option]
  data : string option; [@json.option]
  filename : string option; [@json.option]
  tool_call_id : string option; [@json.key "toolCallId"] [@json.option]
  tool_name : string option; [@json.key "toolName"] [@json.option]
  state : string option; [@json.option]
  input : Melange_json.t option; [@json.option]
  output : Melange_json.t option; [@json.option]
  error_text : string option; [@json.key "errorText"] [@json.option]
  approved : bool option; [@json.option]
  approval : parsed_approval option; [@json.option]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type chat_message = {
  role : string;
  parts : parsed_part list; [@json.default []]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type chat_request = { messages : chat_message list } [@@json.allow_extra_fields] [@@deriving of_json]

(** Extract tool name from [toolName] field, falling back to the type prefix
    (e.g. ["tool-get_weather"] -> ["get_weather"]). *)
let resolve_tool_name (p : parsed_part) =
  match p.tool_name with
  | Some name -> Some name
  | None ->
    let t = p.type_ in
    let prefix = "tool-" in
    let plen = String.length prefix in
    (match String.length t > plen && String.sub t 0 plen = prefix with
    | true -> Some (String.sub t plen (String.length t - plen))
    | false -> None)

(** Extract approved status: check top-level [approved] first, then [approval.approved]. *)
let resolve_approved (p : parsed_part) =
  match p.approved with
  | Some v -> Some v
  | None ->
  match p.approval with
  | Some a -> a.approved
  | None -> None

let parse_file_data (p : parsed_part) =
  match p.media_type with
  | Some media_type ->
    let data =
      match p.url, p.data with
      | Some url, _ -> Some (Ai_provider.Prompt.Url url)
      | _, Some d -> Some (Ai_provider.Prompt.Base64 d)
      | None, None -> None
    in
    Option.map (fun data -> data, media_type, p.filename) data
  | None -> None

let parse_user_part (p : parsed_part) : Ai_provider.Prompt.user_part option =
  match part_type_of_string p.type_ with
  | Text -> Option.map (fun text : Ai_provider.Prompt.user_part -> Text { text; provider_options = empty_opts }) p.text
  | File ->
    Option.map
      (fun (data, media_type, filename) : Ai_provider.Prompt.user_part ->
        File { data; media_type; filename; provider_options = empty_opts })
      (parse_file_data p)
  | Reasoning | Step_start | Source | Tool_invocation _ -> None

let parse_assistant_part (p : parsed_part) : Ai_provider.Prompt.assistant_part option =
  match part_type_of_string p.type_ with
  | Text -> Option.map (fun text -> Ai_provider.Prompt.Text { text; provider_options = empty_opts }) p.text
  | Reasoning -> Option.map (fun text -> Ai_provider.Prompt.Reasoning { text; provider_options = empty_opts }) p.text
  | File ->
    Option.map
      (fun (data, media_type, filename) ->
        Ai_provider.Prompt.File { data; media_type; filename; provider_options = empty_opts })
      (parse_file_data p)
  | Step_start | Source | Tool_invocation _ -> None

let parse_tool_call (p : parsed_part) : Ai_provider.Prompt.assistant_part option =
  match part_type_of_string p.type_ with
  | Tool_invocation _ ->
    (match p.tool_call_id, resolve_tool_name p, p.input with
    | Some id, Some name, Some args ->
      Some (Ai_provider.Prompt.Tool_call { id; name; args; provider_options = empty_opts })
    | _ -> None)
  | _ -> None

let parse_tool_result (p : parsed_part) : Ai_provider.Prompt.tool_result option =
  match part_type_of_string p.type_ with
  | Tool_invocation _ ->
    let state = Option.map tool_state_of_string p.state in
    let tool_name = resolve_tool_name p in
    (match state, p.tool_call_id, tool_name with
    | Some Output_available, Some tool_call_id, Some tool_name ->
      let result = Option.value ~default:`Null p.output in
      Some
        {
          Ai_provider.Prompt.tool_call_id;
          tool_name;
          result;
          is_error = false;
          content = [];
          provider_options = empty_opts;
        }
    | Some Output_error, Some tool_call_id, Some tool_name ->
      let result =
        match p.error_text with
        | Some e -> `String e
        | None -> `String "Tool execution failed"
      in
      Some
        {
          Ai_provider.Prompt.tool_call_id;
          tool_name;
          result;
          is_error = true;
          content = [];
          provider_options = empty_opts;
        }
    | Some Output_denied, Some tool_call_id, Some tool_name ->
      Some
        {
          Ai_provider.Prompt.tool_call_id;
          tool_name;
          result = `String "Tool execution denied";
          is_error = true;
          content = [];
          provider_options = empty_opts;
        }
    | Some Approval_responded, _, _ ->
      (* Both approved and denied are handled by the initial tool execution step
         in stream_text/generate_text — no tool result in the parsed messages *)
      None
    | _ -> None)
  | _ -> None

let parse_messages_from_body body_json =
  try
    let { messages } = chat_request_of_json body_json in
    List.concat_map
      (fun (msg : chat_message) ->
        match role_of_string msg.role with
        | Some System ->
          let text =
            msg.parts
            |> List.filter_map (fun (p : parsed_part) ->
              match part_type_of_string p.type_ with
              | Text -> p.text
              | _ -> None)
            |> String.concat ""
          in
          [ Ai_provider.Prompt.System { content = text } ]
        | Some User ->
          let content = List.filter_map parse_user_part msg.parts in
          (match content with
          | [] -> []
          | content -> [ Ai_provider.Prompt.User { content } ])
        | Some Assistant ->
          (* Split parts into steps at step-start boundaries *)
          let steps = ref [] in
          let current_step = ref [] in
          List.iter
            (fun p ->
              match part_type_of_string p.type_ with
              | Step_start ->
                (match !current_step with
                | [] -> ()
                | parts -> steps := List.rev parts :: !steps);
                current_step := []
              | _ -> current_step := p :: !current_step)
            msg.parts;
          (match !current_step with
          | [] -> ()
          | parts -> steps := List.rev parts :: !steps);
          (* For each step, emit Assistant + Tool messages *)
          List.concat_map
            (fun step_parts ->
              let assistant_parts =
                List.filter_map
                  (fun p ->
                    match part_type_of_string p.type_ with
                    | Tool_invocation _ -> parse_tool_call p
                    | _ -> parse_assistant_part p)
                  step_parts
              in
              let tool_results = List.filter_map parse_tool_result step_parts in
              let msgs =
                match assistant_parts with
                | [] -> []
                | content -> [ Ai_provider.Prompt.Assistant { content } ]
              in
              match tool_results with
              | [] -> msgs
              | content -> msgs @ [ Ai_provider.Prompt.Tool { content } ])
            (List.rev !steps)
        | None -> [])
      messages
  with Melange_json.Of_json_error _ -> []

let collect_pending_tool_approvals body_json =
  try
    let { messages } = chat_request_of_json body_json in
    List.concat_map
      (fun (msg : chat_message) ->
        List.filter_map
          (fun (p : parsed_part) ->
            match part_type_of_string p.type_, Option.map tool_state_of_string p.state with
            | Tool_invocation _, Some Approval_responded ->
              (match p.tool_call_id, resolve_tool_name p, resolve_approved p with
              | Some tool_call_id, Some tool_name, Some approved ->
                let args =
                  match p.input with
                  | Some json -> (json : Melange_json.t :> Yojson.Basic.t)
                  | None -> `Null
                in
                Some { Generate_text_result.tool_call_id; tool_name; args; approved }
              | _ -> None)
            | _ -> None)
          msg.parts)
      messages
  with Melange_json.Of_json_error _ -> []

let cors_headers =
  [
    "access-control-allow-origin", "*";
    "access-control-allow-methods", "POST, OPTIONS";
    "access-control-allow-headers", "content-type";
    "access-control-expose-headers", "x-vercel-ai-ui-message-stream";
  ]

let make_sse_response ?(status = `OK) ?(extra_headers = []) sse_stream =
  let headers = Ui_message_stream.headers @ extra_headers |> Cohttp.Header.of_list in
  let body = Cohttp_lwt.Body.of_stream sse_stream in
  let response = Cohttp.Response.make ~status ~headers () in
  Lwt.return (response, body)

let handle_cors_preflight _conn _req _body =
  let headers = Cohttp.Header.of_list cors_headers in
  let response = Cohttp.Response.make ~status:`No_content ~headers () in
  Lwt.return (response, Cohttp_lwt.Body.empty)

let handle_chat ~model ?tools ?max_steps ?stop_when ?system ?output ?send_reasoning ?max_output_tokens ?(cors = true)
  ?provider_options ?transform _conn _req body =
  let%lwt body_str = Cohttp_lwt.Body.to_string body in
  let body_json =
    try Ok (Yojson.Basic.from_string body_str)
    with Yojson.Json_error msg ->
      Printf.eprintf "[ai_core] handle_chat: invalid JSON in request body: %s\n%!" msg;
      Error msg
  in
  match body_json with
  | Error msg ->
    let status = `Bad_request in
    let headers = (if cors then cors_headers else []) |> Cohttp.Header.of_list in
    let body = Cohttp_lwt.Body.of_string (Printf.sprintf {|{"error":"Invalid JSON: %s"}|} msg) in
    Lwt.return (Cohttp.Response.make ~status ~headers (), body)
  | Ok body_json ->
    let messages = parse_messages_from_body body_json in
    let messages =
      match system with
      | Some s -> Ai_provider.Prompt.System { content = s } :: messages
      | None -> messages
    in
    let pending_tool_approvals = collect_pending_tool_approvals body_json in
    let result =
      Stream_text.stream_text ~model ~messages ?tools ?max_steps ?stop_when ?output ?provider_options ?transform
        ~pending_tool_approvals ()
    in
    let sse_stream = Stream_text_result.to_ui_message_sse_stream ?send_reasoning result in
    let extra_headers = if cors then cors_headers else [] in
    make_sse_response ~extra_headers sse_stream
