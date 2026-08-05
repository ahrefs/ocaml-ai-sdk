let warning feature details = Ai_provider.Warning.Unsupported_feature { feature; details }

let is_known_model = function
  | Model_catalog.Custom _ -> false
  | _ -> true

let effective_thinking_active ~capabilities ~thinking =
  match thinking with
  | Some (Thinking.Enabled _ | Thinking.Adaptive _) -> true
  | Some Thinking.Disabled -> false
  | None ->
  match capabilities.Model_catalog.thinking with
  | Some { defaults_to_adaptive; _ } -> defaults_to_adaptive
  | None -> false

let validate_options ~model ~capabilities ~anthropic_opts ~tool_choice ~forced_tool_choice =
  (match capabilities.Model_catalog.thinking, anthropic_opts.Anthropic_options.thinking with
  | Some thinking, Some (Thinking.Enabled _) when not thinking.manual ->
    invalid_arg (Printf.sprintf "%s does not support manual thinking" model)
  | Some thinking, Some (Thinking.Adaptive _) when not thinking.adaptive ->
    invalid_arg (Printf.sprintf "%s does not support adaptive thinking" model)
  | Some { disabled = Model_catalog.Unsupported; _ }, Some Thinking.Disabled ->
    invalid_arg (Printf.sprintf "%s does not support disabled thinking" model)
  | None, _ | _, None | Some _, Some Thinking.Disabled -> ()
  | Some _, Some (Thinking.Enabled _ | Thinking.Adaptive _) -> ());
  (match capabilities.Model_catalog.thinking, anthropic_opts.Anthropic_options.effort with
  | Some thinking, Some effort when not (List.mem effort thinking.effort_levels) ->
    invalid_arg (Printf.sprintf "%s does not support effort '%s'" model (Effort.to_string effort))
  | None, _ | Some _, None | Some _, Some _ -> ());
  match anthropic_opts.Anthropic_options.thinking with
  | Some (Thinking.Enabled _)
    when (match tool_choice with
           | Some (Ai_provider.Tool_choice.Required | Ai_provider.Tool_choice.Specific _) -> true
           | None | Some (Ai_provider.Tool_choice.Auto | Ai_provider.Tool_choice.None_) -> false)
         || Option.is_some forced_tool_choice ->
    invalid_arg "manual thinking cannot be combined with forced tool choice"
  | _ -> ()

let normalize_sampling ~model ~known_model ~capabilities ~thinking_active (opts : Ai_provider.Call_options.t) =
  let base_warnings =
    List.concat
      [
        (match opts.frequency_penalty with
        | Some _ -> [ warning "frequency_penalty" None ]
        | None -> []);
        (match opts.presence_penalty with
        | Some _ -> [ warning "presence_penalty" None ]
        | None -> []);
        (match opts.seed with
        | Some _ -> [ warning "seed" None ]
        | None -> []);
      ]
  in
  let drop field details = function
    | Some _ -> None, [ warning field (Some details) ]
    | None -> None, []
  in
  let rejects_sampling = capabilities.Model_catalog.rejects_sampling_parameters in
  let model_restriction = Printf.sprintf "not supported by %s and will be ignored" model in
  let thinking_restriction = "not supported when thinking is enabled" in
  let temperature, temperature_warnings =
    if rejects_sampling then drop "temperature" model_restriction opts.temperature
    else if thinking_active then drop "temperature" thinking_restriction opts.temperature
    else opts.temperature, []
  in
  let top_p, top_p_warnings =
    if rejects_sampling then drop "top_p" model_restriction opts.top_p
    else (
      match thinking_active, opts.top_p with
      | true, Some value when value < 0.95 || value > 1. ->
        drop "top_p" "must be between 0.95 and 1 when thinking is enabled" opts.top_p
      | _ -> opts.top_p, [])
  in
  let top_k, top_k_warnings =
    if rejects_sampling then drop "top_k" model_restriction opts.top_k
    else if thinking_active then drop "top_k" thinking_restriction opts.top_k
    else opts.top_k, []
  in
  let top_p, top_p_warning =
    match known_model, temperature, top_p with
    | true, Some _, Some _ ->
      None, [ warning "top_p" (Some "top_p is not supported when temperature is set. top_p is ignored.") ]
    | _, _, _ -> top_p, []
  in
  temperature, top_p, top_k, base_warnings @ temperature_warnings @ top_p_warnings @ top_k_warnings @ top_p_warning

let normalize_disabled_effort ~model ~capabilities ~anthropic_opts =
  match capabilities.Model_catalog.thinking, anthropic_opts.Anthropic_options.thinking, anthropic_opts.effort with
  | Some { disabled = Model_catalog.Up_to_high; _ }, Some Thinking.Disabled, Some (Effort.Xhigh | Effort.Max) ->
    ( Some Effort.High,
      [
        warning "providerOptions.anthropic.effort"
          (Some (Printf.sprintf "effort is not supported by %s when thinking is disabled; lowered to 'high'" model));
      ] )
  | _, _, effort -> effort, []

(** Prepare the request body and warnings — shared by generate and stream. *)
let prepare_request ~model ~stream (opts : Ai_provider.Call_options.t) =
  let known_model = Model_catalog.of_model_id model in
  let capabilities = Model_catalog.capabilities known_model in
  let known_model = is_known_model known_model in
  let anthropic_opts =
    Anthropic_options.of_provider_options opts.provider_options
    |> Stdlib.Option.value ~default:Anthropic_options.default
  in
  let thinking_active = effective_thinking_active ~capabilities ~thinking:anthropic_opts.thinking in
  let temperature, top_p, top_k, warnings =
    normalize_sampling ~model ~known_model ~capabilities ~thinking_active opts
  in
  let effort, effort_warnings = normalize_disabled_effort ~model ~capabilities ~anthropic_opts in
  let anthropic_opts = { anthropic_opts with effort } in
  let warnings = warnings @ effort_warnings in
  (* One validator per request — shared across system, tools, and messages
     so the 4-breakpoint limit covers them all. Upstream order matches
     this: system blocks, then tools, then messages. *)
  let validator = Cache_control_validator.create () in
  let system_parts, remaining = Convert_prompt.extract_system opts.prompt in
  let system = Convert_prompt.system_to_json ~validator system_parts in
  (* Route Object_json per-model: native output_config where supported, synthetic [json]
     tool with forced tool_choice otherwise — matches upstream @ai-sdk/anthropic. *)
  let supports_native_structured_output = capabilities.supports_structured_output in
  let output_format, fallback_tool, forced_tool_choice, extra_warnings =
    match opts.mode with
    | Regular | Object_tool _ -> None, None, None, []
    | Object_json (Some { name = _; schema }) when supports_native_structured_output ->
      Some Anthropic_api.{ type_ = "json_schema"; schema }, None, None, []
    | Object_json (Some { name = _; schema }) ->
      let tool = Convert_tools.json_response_tool ~schema in
      None, Some tool, Some Convert_tools.forced_json_tool_choice, []
    | Object_json None ->
      ( None,
        None,
        None,
        [
          Ai_provider.Warning.Unsupported_feature
            {
              feature = "response_format without schema";
              details = Some "Anthropic structured outputs require a JSON schema; sending request without enforcement";
            };
        ] )
  in
  validate_options ~model ~capabilities ~anthropic_opts ~tool_choice:opts.tool_choice ~forced_tool_choice;
  let output_config =
    match output_format, anthropic_opts.effort with
    | None, None -> None
    | format, effort -> Some Anthropic_api.{ format; effort = Option.map Effort.to_string effort }
  in
  let warnings = warnings @ extra_warnings in
  let base_tools, base_tool_choice =
    Convert_tools.convert_tools ~validator ~tools:opts.tools ~tool_choice:opts.tool_choice ()
  in
  let messages = Convert_prompt.convert_messages ~validator remaining in
  let tools = Option.fold ~none:base_tools ~some:(fun t -> base_tools @ [ t ]) fallback_tool in
  (* When structured-output fallback is active, override the caller's tool_choice. *)
  let tool_choice =
    match forced_tool_choice with
    | Some _ -> forced_tool_choice
    | None -> base_tool_choice
  in
  (* Use model-aware default for max_tokens *)
  let max_tokens =
    Some
      (match opts.max_output_tokens with
      | Some n -> n
      | None -> Model_catalog.default_max_tokens (Model_catalog.of_model_id model))
  in
  let body =
    Anthropic_api.make_request_body ~model ~messages ?system ~tools ?tool_choice ?max_tokens ?temperature ?top_p ?top_k
      ~stop_sequences:opts.stop_sequences ?thinking:anthropic_opts.thinking ?output_config ~stream ()
  in
  (* Merge user headers with required beta headers — the result includes all of opts.headers
     plus a merged anthropic-beta header, so it replaces opts.headers entirely *)
  let required_betas =
    Beta_headers.required_betas ~thinking:anthropic_opts.thinking ~has_pdf:false
      ~tool_streaming:anthropic_opts.tool_streaming
  in
  let extra_headers = Beta_headers.merge_beta_headers ~user_headers:opts.headers ~required:required_betas in
  let warnings = warnings @ Cache_control_validator.warnings validator in
  body, warnings, extra_headers

let create ~config ~model =
  let module M = struct
    let specification_version = "V3"
    let provider = "anthropic"
    let model_id = model

    let generate opts =
      let body, warnings, extra_headers = prepare_request ~model ~stream:false opts in
      match%lwt Anthropic_api.messages ~config ~body ~extra_headers ~stream:false with
      | `Json json ->
        let result = Convert_response.parse_response json in
        Lwt.return { result with warnings = warnings @ result.warnings }
      | `Stream _ -> Lwt.fail_with "unexpected streaming response for non-streaming request"

    let stream opts =
      let body, warnings, extra_headers = prepare_request ~model ~stream:true opts in
      match%lwt Anthropic_api.messages ~config ~body ~extra_headers ~stream:true with
      | `Stream line_stream ->
        let sse_events = Sse.parse_events line_stream in
        let parts = Convert_stream.transform sse_events ~warnings in
        Lwt.return { Ai_provider.Stream_result.stream = parts; warnings; raw_response = None }
      | `Json _ -> Lwt.fail_with "unexpected non-streaming response for streaming request"
  end in
  (module M : Ai_provider.Language_model.S)
