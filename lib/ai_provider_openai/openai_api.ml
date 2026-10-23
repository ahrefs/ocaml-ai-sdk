open Melange_json.Primitives
module Http_client = Ai_provider.Http_client

type stream_options = { include_usage : bool } [@@deriving to_json]

type request_body = {
  model : string;
  messages : Melange_json.t list;
  temperature : float option; [@json.option] [@json.drop_default]
  top_p : float option; [@json.option] [@json.drop_default]
  max_tokens : int option; [@json.option] [@json.drop_default]
  max_completion_tokens : int option; [@json.option] [@json.drop_default]
  frequency_penalty : float option; [@json.option] [@json.drop_default]
  presence_penalty : float option; [@json.option] [@json.drop_default]
  stop : string list option; [@json.option] [@json.drop_default]
  seed : int option; [@json.option] [@json.drop_default]
  response_format : Melange_json.t option; [@json.option] [@json.drop_default]
  tools : Melange_json.t list option; [@json.option] [@json.drop_default]
  tool_choice : Melange_json.t option; [@json.option] [@json.drop_default]
  parallel_tool_calls : bool option; [@json.option] [@json.drop_default]
  logit_bias : Melange_json.t option; [@json.option] [@json.drop_default]
  logprobs : bool option; [@json.option] [@json.drop_default]
  top_logprobs : int option; [@json.option] [@json.drop_default]
  user : string option; [@json.option] [@json.drop_default]
  reasoning_effort : string option; [@json.option] [@json.drop_default]
  store : bool option; [@json.option] [@json.drop_default]
  metadata : Melange_json.t option; [@json.option] [@json.drop_default]
  prediction : Melange_json.t option; [@json.option] [@json.drop_default]
  service_tier : string option; [@json.option] [@json.drop_default]
  stream : bool option; [@json.option] [@json.drop_default]
  stream_options : stream_options option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

let make_request_body ~model ~messages ?temperature ?top_p ?max_tokens ?max_completion_tokens ?frequency_penalty
  ?presence_penalty ?stop ?seed ?response_format ?tools ?tool_choice ?parallel_tool_calls ?logit_bias ?logprobs
  ?top_logprobs ?user ?reasoning_effort ?store ?metadata ?prediction ?service_tier ~stream () =
  let stop =
    match stop with
    | Some (_ :: _ as ss) -> Some ss
    | Some [] | None -> None
  in
  let tools =
    match tools with
    | Some (_ :: _ as ts) -> Some ts
    | Some [] | None -> None
  in
  let stream_val, stream_options =
    match stream with
    | true -> Some true, Some { include_usage = true }
    | false -> None, None
  in
  {
    model;
    messages;
    temperature;
    top_p;
    max_tokens;
    max_completion_tokens;
    frequency_penalty;
    presence_penalty;
    stop;
    seed;
    response_format;
    tools;
    tool_choice;
    parallel_tool_calls;
    logit_bias;
    logprobs;
    top_logprobs;
    user;
    reasoning_effort;
    store;
    metadata;
    prediction;
    service_tier;
    stream = stream_val;
    stream_options;
  }

let make_headers ~(config : Config.t) ~extra_headers =
  let base_headers = [ "content-type", "application/json" ] in
  let auth_headers =
    match config.api_key with
    | Some key -> [ "authorization", "Bearer " ^ key ]
    | None -> []
  in
  let org_headers =
    match config.organization with
    | Some org -> [ "openai-organization", org ]
    | None -> []
  in
  let project_headers =
    match config.project with
    | Some proj -> [ "openai-project", proj ]
    | None -> []
  in
  base_headers @ auth_headers @ org_headers @ project_headers @ config.default_headers @ extra_headers

let chat_completions ?abort_signal ~config ~body ~extra_headers ~stream () =
  let body_json = request_body_to_json body in
  match config.Config.fetch with
  | Some fetch ->
    let headers = make_headers ~config ~extra_headers in
    let body_str = Yojson.Basic.to_string body_json in
    let%lwt json =
      Ai_provider.Abort_signal.race abort_signal (fun () ->
        fetch ~abort_signal ~url:(config.base_url ^ "/chat/completions") ~headers ~body:body_str)
    in
    Lwt.return (`Json json)
  | None ->
    let headers = make_headers ~config ~extra_headers in
    let body = Yojson.Basic.to_string body_json in
    let%lwt response =
      Http_client.post ?abort_signal ~timeouts:config.timeouts ~provider:"openai" ~headers ~body
        (config.base_url ^ "/chat/completions")
    in
    let status = Http_client.status response in
    (match status >= 400, stream with
    | true, _ ->
      let%lwt body = Http_client.error_body response in
      let retry_after_ms = Http_client.header response "retry-after-ms" in
      let retry_after = Http_client.header response "retry-after" in
      let err = Openai_error.of_response ~retry_after_ms ~retry_after ~status ~body () in
      Lwt.fail (Ai_provider.Provider_error.Provider_error err)
    | false, true -> Lwt.return (`Stream (Http_client.body_lines response))
    | false, false ->
      let%lwt body = Http_client.body_string response in
      Lwt.return (`Json (Yojson.Basic.from_string body)))
