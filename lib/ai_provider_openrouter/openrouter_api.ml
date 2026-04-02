open Melange_json.Primitives

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
  reasoning_effort : string option; [@json.option] [@json.drop_default]
  plugins : Melange_json.t list option; [@json.option] [@json.drop_default]
  transforms : string list option; [@json.option] [@json.drop_default]
  route : string option; [@json.option] [@json.drop_default]
  provider : Melange_json.t option; [@json.option] [@json.drop_default]
  api_keys : Melange_json.t option; [@json.option] [@json.drop_default]
  include_reasoning : bool option; [@json.option] [@json.drop_default]
  stream : bool option; [@json.option] [@json.drop_default]
  stream_options : stream_options option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

let non_empty = function
  | Some (_ :: _ as xs) -> Some xs
  | Some [] | None -> None

let make_request_body ~model ~messages ?temperature ?top_p ?max_tokens ?max_completion_tokens ?frequency_penalty
  ?presence_penalty ?stop ?seed ?response_format ?tools ?tool_choice ?parallel_tool_calls ?reasoning_effort ?plugins
  ?transforms ?route ?provider ?api_keys ?include_reasoning ~stream () =
  let stop = non_empty stop in
  let tools = non_empty tools in
  let plugins = non_empty plugins in
  let transforms = non_empty transforms in
  let include_reasoning =
    match include_reasoning with
    | Some true -> Some true
    | Some false | None -> None
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
    reasoning_effort;
    plugins;
    transforms;
    route;
    provider;
    api_keys;
    include_reasoning;
    stream = stream_val;
    stream_options;
  }

let make_headers ~(config : Config.t) ~extra_headers =
  let optional_headers =
    List.filter_map Fun.id
      [
        Option.map (fun key -> "authorization", "Bearer " ^ key) config.api_key;
        Option.map (fun title -> "x-title", title) config.app_title;
        Option.map (fun url -> "http-referer", url) config.app_url;
      ]
  in
  ("content-type", "application/json") :: optional_headers @ config.default_headers @ extra_headers

let body_to_line_stream body =
  let raw_stream = Cohttp_lwt.Body.to_stream body in
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
    if Buffer.length buf > 0 then push (Some (Buffer.contents buf));
    push None;
    Lwt.return_unit);
  line_stream

let chat_completions ~config ~body ~extra_headers ~stream =
  let body_json = request_body_to_json body in
  match config.Config.fetch with
  | Some fetch ->
    let headers = make_headers ~config ~extra_headers in
    let body_str = Yojson.Basic.to_string body_json in
    let%lwt json = fetch ~url:(config.base_url ^ "/chat/completions") ~headers ~body:body_str in
    Lwt.return (`Json json)
  | None ->
    let url = config.base_url ^ "/chat/completions" in
    let uri = Uri.of_string url in
    let headers = make_headers ~config ~extra_headers in
    let cohttp_headers = Cohttp.Header.of_list headers in
    let body_str = Yojson.Basic.to_string body_json in
    let cohttp_body = Cohttp_lwt.Body.of_string body_str in
    let%lwt resp, resp_body = Cohttp_lwt_unix.Client.post ~headers:cohttp_headers ~body:cohttp_body uri in
    let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
    (match status >= 400, stream with
    | true, _ ->
      let%lwt body_str = Cohttp_lwt.Body.to_string resp_body in
      let err = Openrouter_error.of_response ~status ~body:body_str in
      Lwt.fail (Ai_provider.Provider_error.Provider_error err)
    | false, true -> Lwt.return (`Stream (body_to_line_stream resp_body))
    | false, false ->
      let%lwt body_str = Cohttp_lwt.Body.to_string resp_body in
      let json = Yojson.Basic.from_string body_str in
      Lwt.return (`Json json))
