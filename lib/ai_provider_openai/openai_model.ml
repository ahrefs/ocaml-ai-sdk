open Melange_json.Primitives

(* --- Response format types --- *)

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

(** Check for unsupported features and emit warnings. *)
let check_unsupported ~is_reasoning (opts : Ai_provider.Call_options.t) =
  let warnings = ref [] in
  let warn feature details = warnings := Ai_provider.Warning.Unsupported_feature { feature; details } :: !warnings in
  Stdlib.Option.iter (fun _ -> warn "top_k" (Some "OpenAI does not support top_k")) opts.top_k;
  if is_reasoning then begin
    Stdlib.Option.iter (fun _ -> warn "temperature" (Some "Not supported for reasoning models")) opts.temperature;
    Stdlib.Option.iter (fun _ -> warn "top_p" (Some "Not supported for reasoning models")) opts.top_p;
    Stdlib.Option.iter
      (fun _ -> warn "frequency_penalty" (Some "Not supported for reasoning models"))
      opts.frequency_penalty;
    Stdlib.Option.iter
      (fun _ -> warn "presence_penalty" (Some "Not supported for reasoning models"))
      opts.presence_penalty
  end;
  List.rev !warnings

(** Build response_format JSON from the mode. *)
let build_response_format ~strict_json_schema (mode : Ai_provider.Mode.t) =
  match mode with
  | Regular | Object_tool _ -> None
  | Object_json None -> Some (json_object_format_to_json { type_ = "json_object" })
  | Object_json (Some { name; schema }) ->
    Some
      (json_schema_format_to_json
         { type_ = "json_schema"; json_schema = { name; schema; strict = strict_json_schema } })

(** Build logit_bias JSON from options. *)
let build_logit_bias = function
  | [] -> None
  | pairs -> Some (`Assoc (List.map (fun (token_id, bias) -> string_of_int token_id, `Float bias) pairs))

(** Build metadata JSON from options. *)
let build_metadata = function
  | [] -> None
  | pairs -> Some (`Assoc (List.map (fun (k, v) -> k, `String v) pairs))

type prediction_json = {
  type_ : string; [@json.key "type"]
  content : string;
}
[@@deriving to_json]

(** Build prediction JSON from options. *)
let build_prediction = function
  | None -> None
  | Some (p : Openai_options.prediction) -> Some (prediction_json_to_json { type_ = p.type_; content = p.content })

(** Prepare the request body and warnings — shared by generate and stream. *)
let prepare_request ~model ~stream (opts : Ai_provider.Call_options.t) =
  let model_caps = Model_catalog.capabilities model in
  let openai_opts =
    Openai_options.of_provider_options opts.provider_options |> Stdlib.Option.value ~default:Openai_options.default
  in
  let warnings = check_unsupported ~is_reasoning:model_caps.is_reasoning_model opts in
  let system_message_mode =
    match openai_opts.system_message_mode with
    | Some mode -> mode
    | None -> model_caps.system_message_mode
  in
  let messages, prompt_warnings = Convert_prompt.convert_messages ~system_message_mode opts.prompt in
  let messages_json = List.map Convert_prompt.openai_message_to_json messages in
  let warnings = warnings @ prompt_warnings in
  let tools_json, tool_choice_json =
    match opts.mode with
    | Object_tool { tool_name; schema = { name = _; schema } } ->
      let tool =
        { Ai_provider.Tool.name = tool_name; description = Some "Structured output tool"; parameters = schema }
      in
      let tools =
        List.map Convert_tools.openai_tool_to_json
          (Convert_tools.convert_tools ~strict:openai_opts.strict_json_schema [ tool ])
      in
      let tc = Convert_tools.convert_tool_choice (Specific { tool_name }) in
      Some tools, Some tc
    | Regular | Object_json _ ->
    match opts.tools with
    | [] -> None, None
    | tools ->
      let tools_json =
        List.map Convert_tools.openai_tool_to_json
          (Convert_tools.convert_tools ~strict:openai_opts.strict_json_schema tools)
      in
      let tc_json = Stdlib.Option.map Convert_tools.convert_tool_choice opts.tool_choice in
      Some tools_json, tc_json
  in
  let response_format = build_response_format ~strict_json_schema:openai_opts.strict_json_schema opts.mode in
  let max_tokens, max_completion_tokens =
    match model_caps.is_reasoning_model, openai_opts.max_completion_tokens, opts.max_output_tokens with
    | true, Some n, _ -> None, Some n
    | true, None, max_out -> None, max_out
    | false, _, Some n -> Some n, None
    | false, _, None -> Some model_caps.default_max_tokens, None
  in
  let temperature, top_p, frequency_penalty, presence_penalty =
    match model_caps.is_reasoning_model with
    | true -> None, None, None, None
    | false -> opts.temperature, opts.top_p, opts.frequency_penalty, opts.presence_penalty
  in
  let reasoning_effort = Stdlib.Option.map Openai_options.reasoning_effort_to_string openai_opts.reasoning_effort in
  let service_tier = Stdlib.Option.map Openai_options.service_tier_to_string openai_opts.service_tier in
  let logit_bias = build_logit_bias openai_opts.logit_bias in
  let metadata = build_metadata openai_opts.metadata in
  let prediction = build_prediction openai_opts.prediction in
  let logprobs, top_logprobs =
    match openai_opts.logprobs with
    | Some n -> Some true, Some n
    | None -> None, None
  in
  let stop =
    match opts.stop_sequences with
    | [] -> None
    | ss -> Some ss
  in
  let body =
    Openai_api.make_request_body ~model ~messages:messages_json ?temperature ?top_p ?max_tokens ?max_completion_tokens
      ?frequency_penalty ?presence_penalty ?stop ?seed:opts.seed ?response_format ?tools:tools_json
      ?tool_choice:tool_choice_json ?parallel_tool_calls:openai_opts.parallel_tool_calls ?logit_bias ?logprobs
      ?top_logprobs ?user:openai_opts.user ?reasoning_effort ?store:openai_opts.store ?metadata ?prediction
      ?service_tier ~stream ()
  in
  body, warnings

let create ~config ~model =
  let module M = struct
    let specification_version = "v1"
    let provider = "openai"
    let model_id = model

    let generate opts =
      let body, warnings = prepare_request ~model ~stream:false opts in
      let%lwt response = Openai_api.chat_completions ~config ~body ~extra_headers:opts.headers ~stream:false in
      match response with
      | `Json json ->
        let result = Convert_response.parse_response json in
        Lwt.return { result with warnings = warnings @ result.warnings }
      | `Stream _ -> Lwt.fail_with "unexpected streaming response for non-streaming request"

    let stream opts =
      let body, warnings = prepare_request ~model ~stream:true opts in
      let%lwt response = Openai_api.chat_completions ~config ~body ~extra_headers:opts.headers ~stream:true in
      match response with
      | `Stream line_stream ->
        let sse_events = Sse.parse_events line_stream in
        let parts = Convert_stream.transform sse_events ~warnings in
        Lwt.return { Ai_provider.Stream_result.stream = parts; warnings; raw_response = None }
      | `Json _ -> Lwt.fail_with "unexpected non-streaming response for streaming request"
  end in
  (module M : Ai_provider.Language_model.S)
