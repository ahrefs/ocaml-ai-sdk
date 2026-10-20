open Melange_json.Primitives
module Http_client = Ai_provider.Http_client

type stream_options = { include_usage : bool } [@@deriving to_json]

type request_body = {
  model : string;
  models : string list option; [@json.option] [@json.drop_default]
  messages : Melange_json.t list;
  temperature : float option; [@json.option] [@json.drop_default]
  top_p : float option; [@json.option] [@json.drop_default]
  top_k : int option; [@json.option] [@json.drop_default]
  max_tokens : int option; [@json.option] [@json.drop_default]
  frequency_penalty : float option; [@json.option] [@json.drop_default]
  presence_penalty : float option; [@json.option] [@json.drop_default]
  stop : string list option; [@json.option] [@json.drop_default]
  seed : int option; [@json.option] [@json.drop_default]
  response_format : Melange_json.t option; [@json.option] [@json.drop_default]
  tools : Melange_json.t list option; [@json.option] [@json.drop_default]
  tool_choice : Melange_json.t option; [@json.option] [@json.drop_default]
  parallel_tool_calls : bool option; [@json.option] [@json.drop_default]
  logit_bias : Melange_json.t option; [@json.option] [@json.drop_default]
  logprobs : Melange_json.t option; [@json.option] [@json.drop_default]
  top_logprobs : Melange_json.t option; [@json.option] [@json.drop_default]
  user : string option; [@json.option] [@json.drop_default]
  (* OpenRouter-specific *)
  include_reasoning : bool option; [@json.option] [@json.drop_default]
  reasoning : Melange_json.t option; [@json.option] [@json.drop_default]
  usage : Melange_json.t option; [@json.option] [@json.drop_default]
  plugins : Melange_json.t list option; [@json.option] [@json.drop_default]
  web_search_options : Melange_json.t option; [@json.option] [@json.drop_default]
  provider : Melange_json.t option; [@json.option] [@json.drop_default]
  debug : Melange_json.t option; [@json.option] [@json.drop_default]
  cache_control : Melange_json.t option; [@json.option] [@json.drop_default]
  stream : bool option; [@json.option] [@json.drop_default]
  stream_options : stream_options option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

let non_empty = function
  | Some (_ :: _ as xs) -> Some xs
  | Some [] | None -> None

let make_request_body ~model ~messages ?models ?temperature ?top_p ?top_k ?max_tokens ?frequency_penalty
  ?presence_penalty ?stop ?seed ?response_format ?tools ?tool_choice ?parallel_tool_calls ?logit_bias ?logprobs
  ?top_logprobs ?user ?include_reasoning ?reasoning ?usage ?plugins ?web_search_options ?provider ?debug ?cache_control
  ~stream ~compatibility () =
  let stop = non_empty stop in
  let tools = non_empty tools in
  let plugins = non_empty plugins in
  let models = non_empty models in
  let include_reasoning =
    match include_reasoning with
    | Some true -> Some true
    | Some false | None -> None
  in
  let stream_val, stream_options =
    match stream with
    | true ->
      ( Some true,
        (match compatibility with
        | Config.Strict -> Some { include_usage = true }
        | Config.Compatible -> None) )
    | false -> None, None
  in
  {
    model;
    models;
    messages;
    temperature;
    top_p;
    top_k;
    max_tokens;
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
    include_reasoning;
    reasoning;
    usage;
    plugins;
    web_search_options;
    provider;
    debug;
    cache_control;
    stream = stream_val;
    stream_options;
  }

let merge_extra_body body_json (extra_body : (string * Yojson.Basic.t) list) =
  match extra_body with
  | [] -> body_json
  | _ ->
  match body_json with
  | `Assoc fields -> `Assoc (fields @ extra_body)
  | other -> other

let make_headers ~(config : Config.t) ~extra_headers =
  let optional_headers =
    List.filter_map Fun.id
      [
        Stdlib.Option.map (fun key -> "authorization", "Bearer " ^ key) config.api_key;
        Stdlib.Option.map (fun title -> "X-OpenRouter-Title", title) config.app_title;
        Stdlib.Option.map (fun url -> "HTTP-Referer", url) config.app_url;
        (match config.api_keys with
        | [] -> None
        | keys ->
          let json = Yojson.Basic.to_string (`Assoc (List.map (fun (k, v) -> k, `String v) keys)) in
          Some ("X-Provider-API-Keys", json));
      ]
  in
  (("content-type", "application/json") :: optional_headers) @ config.default_headers @ extra_headers

let check_200_error json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
    | Some (`Assoc error_fields) ->
      let err = Openrouter_error.of_error_json (`Assoc error_fields) in
      Lwt.fail (Ai_provider.Provider_error.Provider_error err)
    | _ -> Lwt.return json)
  | _ -> Lwt.return json

let provider_error_of_http_response ~body response =
  let status = Http_client.status response in
  let retry_after_ms = Http_client.header response "retry-after-ms" in
  let retry_after = Http_client.header response "retry-after" in
  Openrouter_error.of_response_with_retry_after ~retry_after_ms ~status ~body ~retry_after ()

let chat_completions_abortable abort_signal ~config ~body ~extra_body ~extra_headers ~stream =
  let body_json = merge_extra_body (request_body_to_json body) extra_body in
  match config.Config.fetch with
  | Some fetch ->
    let headers = make_headers ~config ~extra_headers in
    let body_str = Yojson.Basic.to_string body_json in
    let%lwt () = Ai_provider.Abort_signal.fail_if_aborted abort_signal in
    let%lwt json = fetch ~url:(config.base_url ^ "/chat/completions") ~headers ~body:body_str in
    let%lwt json = check_200_error json in
    Lwt.return (`Json json)
  | None ->
    let headers = make_headers ~config ~extra_headers in
    let body = Yojson.Basic.to_string body_json in
    let%lwt response =
      Http_client.post ?abort_signal ~timeouts:config.timeouts ~provider:"openrouter" ~headers ~body
        (config.base_url ^ "/chat/completions")
    in
    (match Http_client.status response >= 400, stream with
    | true, _ ->
      let%lwt body = Http_client.error_body response in
      Lwt.fail (Ai_provider.Provider_error.Provider_error (provider_error_of_http_response ~body response))
    | false, true -> Lwt.return (`Stream (Http_client.body_lines response))
    | false, false ->
      let%lwt body = Http_client.body_string response in
      let%lwt json = check_200_error (Yojson.Basic.from_string body) in
      Lwt.return (`Json json))

let chat_completions ~config ~body ~extra_body ~extra_headers ~stream =
  chat_completions_abortable None ~config ~body ~extra_body ~extra_headers ~stream
