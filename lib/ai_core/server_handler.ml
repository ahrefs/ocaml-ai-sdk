type message_part = {
  type_ : string; [@key "type"]
  text : string option; [@default None]
}
[@@deriving of_yojson { strict = false }]

type chat_message = {
  role : string;
  content : string option; [@default None]
  parts : message_part list option; [@default None]
}
[@@deriving of_yojson { strict = false }]

type chat_request = { messages : chat_message list } [@@deriving of_yojson { strict = false }]

(* Extract text from a message — handles both v5 "content" string
   and v6 "parts" array formats from useChat *)
let extract_text (msg : chat_message) =
  match msg.parts with
  | Some parts ->
    parts
    |> List.filter_map (fun (p : message_part) ->
      match p.type_, p.text with
      | "text", Some t -> Some t
      | _ -> None)
    |> String.concat ""
  | None -> Option.value ~default:"" msg.content

let parse_messages_from_body body_json =
  match chat_request_of_yojson body_json with
  | Error _ -> []
  | Ok { messages } ->
    List.filter_map
      (fun (msg : chat_message) ->
        let text = extract_text msg in
        match msg.role with
        | "system" -> Some (Ai_provider.Prompt.System { content = text })
        | "user" ->
          Some
            (Ai_provider.Prompt.User
               { content = [ Text { text; provider_options = Ai_provider.Provider_options.empty } ] })
        | "assistant" ->
          Some
            (Ai_provider.Prompt.Assistant
               { content = [ Text { text; provider_options = Ai_provider.Provider_options.empty } ] })
        | _ -> None)
      messages

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

let handle_chat ~model ?tools ?max_steps ?system ?send_reasoning ?(cors = true) ?provider_options _conn _req body =
  let%lwt body_str = Cohttp_lwt.Body.to_string body in
  let body_json =
    try Ok (Yojson.Safe.from_string body_str)
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
  let result = Stream_text.stream_text ~model ~messages ?tools ?max_steps ?provider_options () in
  let sse_stream = Stream_text_result.to_ui_message_sse_stream ?send_reasoning result in
  let extra_headers = if cors then cors_headers else [] in
  make_sse_response ~extra_headers sse_stream
