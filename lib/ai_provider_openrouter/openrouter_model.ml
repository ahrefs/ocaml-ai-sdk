open Melange_json.Primitives

type json_object_format = { type_ : string [@json.key "type"] } [@@deriving to_json]

type json_schema_detail = {
  name : string;
  schema : Melange_json.t;
  strict : bool;
}
[@@deriving to_json]

type json_schema_format = {
  type_ : string; [@json.key "type"]
  json_schema : json_schema_detail;
}
[@@deriving to_json]

(** Build tools and tool_choice JSON from call options and mode. *)
let build_tools_and_choice ~strict (opts : Ai_provider.Call_options.t) =
  match opts.mode with
  | Object_tool { tool_name; schema = { name = _; schema } } ->
    let tool =
      { Ai_provider.Tool.name = tool_name; description = Some "Structured output tool"; parameters = schema }
    in
    let tools = List.map Convert_tools.openai_tool_to_json (Convert_tools.convert_tools ~strict [ tool ]) in
    let tc = Convert_tools.convert_tool_choice (Specific { tool_name }) in
    Some tools, Some tc
  | Regular | Object_json _ ->
  match opts.tools with
  | [] -> None, None
  | tools ->
    let tools_json = List.map Convert_tools.openai_tool_to_json (Convert_tools.convert_tools ~strict tools) in
    let tc_json = Stdlib.Option.map Convert_tools.convert_tool_choice opts.tool_choice in
    Some tools_json, tc_json

(** OpenRouter-specific fields derived from provider options. *)
type openrouter_fields = {
  models : string list option;
  logit_bias : Yojson.Basic.t option;
  logprobs : Yojson.Basic.t option;
  top_logprobs : Yojson.Basic.t option;
  reasoning : Yojson.Basic.t option;
  plugins : Yojson.Basic.t list option;
  web_search_options : Yojson.Basic.t option;
  provider : Yojson.Basic.t option;
  debug : Yojson.Basic.t option;
  cache_control : Yojson.Basic.t option;
  usage : Yojson.Basic.t option;
}

(** Build the OpenRouter-specific optional fields from provider options. *)
let build_openrouter_fields (or_opts : Openrouter_options.t) =
  let models =
    match or_opts.models with
    | [] -> None
    | ms -> Some ms
  in
  let logit_bias =
    match or_opts.logit_bias with
    | [] -> None
    | bias -> Some (Openrouter_options.logit_bias_to_json bias)
  in
  let logprobs, top_logprobs =
    match or_opts.logprobs with
    | None -> None, None
    | Some lp ->
      let l, tl = Openrouter_options.logprobs_to_json lp in
      Some l, tl
  in
  let reasoning = Stdlib.Option.map Openrouter_options.reasoning_config_to_json or_opts.reasoning in
  let plugins =
    match or_opts.plugins with
    | [] -> None
    | ps -> Some (Openrouter_options.plugins_to_json ps)
  in
  let web_search_options = Stdlib.Option.map Openrouter_options.web_search_options_to_json or_opts.web_search_options in
  let provider = Stdlib.Option.map Openrouter_options.provider_prefs_to_json or_opts.provider in
  let debug = Stdlib.Option.map Openrouter_options.debug_config_to_json or_opts.debug in
  let cache_control = Stdlib.Option.map Openrouter_options.cache_control_to_json or_opts.cache_control in
  let usage = Stdlib.Option.map Openrouter_options.usage_config_to_json or_opts.usage in
  {
    models;
    logit_bias;
    logprobs;
    top_logprobs;
    reasoning;
    plugins;
    web_search_options;
    provider;
    debug;
    cache_control;
    usage;
  }

(** Build response_format JSON from the mode. *)
let build_response_format ~strict_json_schema (mode : Ai_provider.Mode.t) =
  match mode with
  | Regular | Object_tool _ -> None
  | Object_json None -> Some (json_object_format_to_json { type_ = "json_object" })
  | Object_json (Some { name; schema }) ->
    Some
      (json_schema_format_to_json
         { type_ = "json_schema"; json_schema = { name; schema; strict = strict_json_schema } })

(** Prepare the request body and warnings -- shared by generate and stream. *)
let prepare_request ~config ~model ~stream (opts : Ai_provider.Call_options.t) =
  let or_opts =
    Openrouter_options.of_provider_options opts.provider_options
    |> Stdlib.Option.value ~default:Openrouter_options.default
  in
  let warnings = [] in
  let system_message_mode =
    match or_opts.system_message_mode with
    | Some mode -> mode
    | None -> Model_catalog.infer_system_message_mode model
  in
  let messages, prompt_warnings = Convert_prompt.convert_messages ~system_message_mode opts.prompt in
  let messages_json = List.map Convert_prompt.openai_message_to_json messages in
  let warnings = warnings @ prompt_warnings in
  let tools_json, tool_choice_json = build_tools_and_choice ~strict:or_opts.strict_json_schema opts in
  let response_format = build_response_format ~strict_json_schema:or_opts.strict_json_schema opts.mode in
  (* Don't inject default max_tokens -- send None when caller doesn't specify *)
  let max_tokens = opts.max_output_tokens in
  let stop =
    match opts.stop_sequences with
    | [] -> None
    | ss -> Some ss
  in
  let or_fields = build_openrouter_fields or_opts in
  let body =
    Openrouter_api.make_request_body ~model ~messages:messages_json ?models:or_fields.models
      ?temperature:opts.temperature ?top_p:opts.top_p ?top_k:opts.top_k ?max_tokens
      ?frequency_penalty:opts.frequency_penalty ?presence_penalty:opts.presence_penalty ?stop ?seed:opts.seed
      ?response_format ?tools:tools_json ?tool_choice:tool_choice_json ?parallel_tool_calls:or_opts.parallel_tool_calls
      ?logit_bias:or_fields.logit_bias ?logprobs:or_fields.logprobs ?top_logprobs:or_fields.top_logprobs
      ?user:or_opts.user ?include_reasoning:or_opts.include_reasoning ?reasoning:or_fields.reasoning
      ?usage:or_fields.usage ?plugins:or_fields.plugins ?web_search_options:or_fields.web_search_options
      ?provider:or_fields.provider ?debug:or_fields.debug ?cache_control:or_fields.cache_control ~stream
      ~compatibility:config.Config.compatibility ()
  in
  (* Merge extra_body: config-level first, then model-level (model takes precedence) *)
  let extra_body = config.extra_body @ or_opts.extra_body in
  body, extra_body, warnings

let create ~config ~model =
  let module M = struct
    let specification_version = "v1"
    let provider = "openrouter"
    let model_id = model

    let generate opts =
      let body, extra_body, warnings = prepare_request ~config ~model ~stream:false opts in
      let%lwt response =
        Openrouter_api.chat_completions ~config ~body ~extra_body ~extra_headers:opts.headers ~stream:false
      in
      match response with
      | `Json json ->
        let result = Convert_response.parse_response json in
        Lwt.return { result with warnings = warnings @ result.warnings }
      | `Stream _ -> Lwt.fail_with "unexpected streaming response for non-streaming request"

    let stream opts =
      let body, extra_body, warnings = prepare_request ~config ~model ~stream:true opts in
      let%lwt response =
        Openrouter_api.chat_completions ~config ~body ~extra_body ~extra_headers:opts.headers ~stream:true
      in
      match response with
      | `Stream line_stream ->
        let sse_events = Sse.parse_events line_stream in
        let parts = Convert_stream.transform sse_events ~warnings in
        Lwt.return { Ai_provider.Stream_result.stream = parts; warnings; raw_response = None }
      | `Json _ -> Lwt.fail_with "unexpected non-streaming response for streaming request"
  end in
  (module M : Ai_provider.Language_model.S)
