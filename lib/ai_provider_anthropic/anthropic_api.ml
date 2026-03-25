open Melange_json.Primitives

type thinking_config = {
  type_ : string; [@json.key "type"]
  budget_tokens : int;
}
[@@deriving to_json]

type request_body = {
  model : string;
  messages : Melange_json.t list;
  system : string option; [@json.option] [@json.drop_default]
  tools : Melange_json.t list option; [@json.option] [@json.drop_default]
  tool_choice : Melange_json.t option; [@json.option] [@json.drop_default]
  max_tokens : int;
  temperature : float option; [@json.option] [@json.drop_default]
  top_p : float option; [@json.option] [@json.drop_default]
  top_k : int option; [@json.option] [@json.drop_default]
  stop_sequences : string list option; [@json.option] [@json.drop_default]
  thinking : thinking_config option; [@json.option] [@json.drop_default]
  stream : bool option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

let make_request_body ~model ~messages ?system ?tools ?tool_choice ?max_tokens ?temperature ?top_p ?top_k
  ?stop_sequences ?thinking ?stream () =
  let messages_json = List.map Convert_prompt.anthropic_message_to_json messages in
  let tools_json =
    match tools with
    | Some (_ :: _ as ts) -> Some (List.map Convert_tools.anthropic_tool_to_json ts)
    | Some [] | None -> None
  in
  let tool_choice_json = Option.map Convert_tools.anthropic_tool_choice_to_json tool_choice in
  let max_tokens =
    (* Fallback for direct API use; anthropic_model.ml always passes model-aware default *)
    match max_tokens with
    | Some n -> n
    | None -> 4096
  in
  let thinking_json =
    match thinking with
    | Some t when t.Thinking.enabled ->
      Some { type_ = "enabled"; budget_tokens = Thinking.to_int t.budget_tokens }
    | Some _ | None -> None
  in
  let stream =
    match stream with
    | Some true -> Some true
    | Some false | None -> None
  in
  let stop_sequences =
    match stop_sequences with
    | Some (_ :: _ as ss) -> Some ss
    | Some [] | None -> None
  in
  request_body_to_json
    {
      model;
      messages = messages_json;
      system;
      tools = tools_json;
      tool_choice = tool_choice_json;
      max_tokens;
      temperature;
      top_p;
      top_k;
      stop_sequences;
      thinking = thinking_json;
      stream;
    }

let make_headers ~(config : Config.t) ~extra_headers =
  let base_headers = [ "content-type", "application/json"; "anthropic-version", "2023-06-01" ] in
  let auth_headers =
    match config.api_key with
    | Some key -> [ "x-api-key", key ]
    | None -> []
  in
  base_headers @ auth_headers @ config.default_headers @ extra_headers

let body_to_line_stream body =
  let raw_stream = Cohttp_lwt.Body.to_stream body in
  (* The raw stream gives us chunks; we need to split into lines *)
  let buf = Buffer.create 256 in
  let line_stream, push = Lwt_stream.create () in
  Lwt.async (fun () ->
    let%lwt () =
      Lwt_stream.iter
        (fun chunk ->
          let len = String.length chunk in
          let i = ref 0 in
          while !i < len do
            let c = String.get chunk !i in
            (match c with
            | '\n' ->
              push (Some (Buffer.contents buf));
              Buffer.clear buf
            | '\r' -> ()
            | c -> Buffer.add_char buf c);
            incr i
          done)
        raw_stream
    in
    (* Flush remaining data *)
    if Buffer.length buf > 0 then push (Some (Buffer.contents buf));
    push None;
    Lwt.return_unit);
  line_stream

let messages ~config ~body ~extra_headers ~stream =
  match config.Config.fetch with
  | Some fetch ->
    (* Use injected fetch function for testing *)
    let headers = make_headers ~config ~extra_headers in
    let body_str = Yojson.Basic.to_string body in
    let%lwt json = fetch ~url:(config.base_url ^ "/messages") ~headers ~body:body_str in
    Lwt.return (`Json json)
  | None ->
    (* Use real HTTP via cohttp *)
    let url = config.base_url ^ "/messages" in
    let uri = Uri.of_string url in
    let headers = make_headers ~config ~extra_headers in
    let cohttp_headers = Cohttp.Header.of_list headers in
    let body_str = Yojson.Basic.to_string body in
    let cohttp_body = Cohttp_lwt.Body.of_string body_str in
    let%lwt resp, resp_body = Cohttp_lwt_unix.Client.post ~headers:cohttp_headers ~body:cohttp_body uri in
    let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
    (match () with
    | () when status >= 400 ->
      let%lwt body_str = Cohttp_lwt.Body.to_string resp_body in
      let err = Anthropic_error.of_response ~status ~body:body_str in
      Lwt.fail (Ai_provider.Provider_error.Provider_error err)
    | () when stream -> Lwt.return (`Stream (body_to_line_stream resp_body))
    | () ->
      let%lwt body_str = Cohttp_lwt.Body.to_string resp_body in
      let json = Yojson.Basic.from_string body_str in
      Lwt.return (`Json json))
