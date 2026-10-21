open Melange_json.Primitives
module Http_client = Ai_provider.Http_client

type thinking_config = {
  type_ : string; [@json.key "type"]
  budget_tokens : int option; [@json.option] [@json.drop_default]
  display : string option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type output_format = {
  type_ : string; [@json.key "type"]
  schema : Melange_json.t;
}
[@@deriving to_json]

type output_config = {
  format : output_format option; [@json.option] [@json.drop_default]
  effort : string option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type request_body = {
  model : string;
  messages : Melange_json.t list;
  system : Melange_json.t option; [@json.option] [@json.drop_default]
  tools : Melange_json.t list option; [@json.option] [@json.drop_default]
  tool_choice : Melange_json.t option; [@json.option] [@json.drop_default]
  max_tokens : int;
  temperature : float option; [@json.option] [@json.drop_default]
  top_p : float option; [@json.option] [@json.drop_default]
  top_k : int option; [@json.option] [@json.drop_default]
  stop_sequences : string list option; [@json.option] [@json.drop_default]
  thinking : thinking_config option; [@json.option] [@json.drop_default]
  output_config : output_config option; [@json.option] [@json.drop_default]
  stream : bool option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

let make_request_body ~model ~messages ?system ?tools ?tool_choice ?max_tokens ?temperature ?top_p ?top_k
  ?stop_sequences ?thinking ?output_config ?stream () =
  let messages_json = List.map Convert_prompt.anthropic_message_to_json messages in
  let tools_json =
    match tools with
    | Some (_ :: _ as ts) -> Some (List.map Convert_tools.anthropic_tool_to_json ts)
    | Some [] | None -> None
  in
  let tool_choice_json = Option.map Convert_tools.anthropic_tool_choice_to_json tool_choice in
  (* Fallback for direct API use; anthropic_model.ml always passes model-aware default *)
  let max_tokens =
    match max_tokens with
    | Some n -> n
    | None -> 4096
  in
  let display_to_string = function
    | Thinking.Summarized -> "summarized"
    | Thinking.Omitted -> "omitted"
  in
  let thinking_json =
    match thinking with
    | None -> None
    | Some Thinking.Disabled -> Some { type_ = "disabled"; budget_tokens = None; display = None }
    | Some (Thinking.Adaptive { display }) ->
      Some { type_ = "adaptive"; budget_tokens = None; display = Option.map display_to_string display }
    | Some (Thinking.Enabled { budget_tokens; display }) ->
      Some
        {
          type_ = "enabled";
          budget_tokens = Some (Thinking.to_int budget_tokens);
          display = Option.map display_to_string display;
        }
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
  let output_config =
    match output_config with
    | Some { format = None; effort = None } -> None
    | _ -> output_config
  in
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
    output_config;
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

let messages ?abort_signal ~config ~body ~extra_headers ~stream () =
  let body_json = request_body_to_json body in
  match config.Config.fetch with
  | Some fetch ->
    let headers = make_headers ~config ~extra_headers in
    let body_str = Yojson.Basic.to_string body_json in
    let%lwt json =
      Ai_provider.Abort_signal.guard abort_signal (fun () ->
        fetch ~abort_signal ~url:(config.base_url ^ "/messages") ~headers ~body:body_str)
    in
    Lwt.return (`Json json)
  | None ->
    let headers = make_headers ~config ~extra_headers in
    let body = Yojson.Basic.to_string body_json in
    let%lwt response =
      Http_client.post ?abort_signal ~timeouts:config.timeouts ~provider:"anthropic" ~headers ~body
        (config.base_url ^ "/messages")
    in
    let status = Http_client.status response in
    (match status >= 400, stream with
    | true, _ ->
      let%lwt body = Http_client.error_body response in
      let retry_after_ms = Http_client.header response "retry-after-ms" in
      let retry_after = Http_client.header response "retry-after" in
      let err = Anthropic_error.of_response ~retry_after_ms ~retry_after ~status ~body () in
      Lwt.fail (Ai_provider.Provider_error.Provider_error err)
    | false, true -> Lwt.return (`Stream (Http_client.body_lines response))
    | false, false ->
      let%lwt body = Http_client.body_string response in
      Lwt.return (`Json (Yojson.Basic.from_string body)))
