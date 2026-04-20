open Melange_json.Primitives

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
      let message =
        match List.assoc_opt "message" error_fields with
        | Some (`String m) -> m
        | _ -> "Unknown error"
      in
      let status =
        match List.assoc_opt "code" error_fields with
        | Some (`Int n) -> n
        | _ -> 200
      in
      let err = Ai_provider.Provider_error.make_api_error ~provider:"openrouter" ~status ~body:message () in
      Lwt.fail (Ai_provider.Provider_error.Provider_error err)
    | _ -> Lwt.return json)
  | _ -> Lwt.return json

let chat_completions ~config ~body ~extra_body ~extra_headers ~stream =
  let body_json = merge_extra_body (request_body_to_json body) extra_body in
  match config.Config.fetch with
  | Some fetch ->
    let headers = make_headers ~config ~extra_headers in
    let body_str = Yojson.Basic.to_string body_json in
    let%lwt json = fetch ~url:(config.base_url ^ "/chat/completions") ~headers ~body:body_str in
    let%lwt json = check_200_error json in
    Lwt.return (`Json json)
  | None ->
    let url = config.base_url ^ "/chat/completions" in
    let uri = Uri.of_string url in
    let headers = make_headers ~config ~extra_headers in
    let cohttp_headers = Cohttp.Header.of_list headers in
    let body_str = Yojson.Basic.to_string body_json in
    let cohttp_body = Cohttp_lwt.Body.of_string body_str in
    let%lwt resp, resp_body =
      Ai_provider.Http_client.post
        ~timeouts:config.timeouts
        ~provider:"openrouter"
        ~headers:cohttp_headers
        ~body:cohttp_body
        uri
    in
    let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
    (match status >= 400, stream with
    | true, _ ->
      let%lwt body_str = Cohttp_lwt.Body.to_string resp_body in
      let err = Openrouter_error.of_response ~status ~body:body_str in
      Lwt.fail (Ai_provider.Provider_error.Provider_error err)
    | false, true ->
      Lwt.return
        (`Stream
          (Ai_provider.Http_client.wrap_body_with_idle_timeout
             ~timeouts:config.timeouts ~provider:"openrouter" resp_body))
    | false, false ->
      let%lwt body_str = Cohttp_lwt.Body.to_string resp_body in
      let json = Yojson.Basic.from_string body_str in
      let%lwt json = check_200_error json in
      Lwt.return (`Json json))
