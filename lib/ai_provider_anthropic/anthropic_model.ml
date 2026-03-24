(** Check for unsupported features and emit warnings. *)
let check_unsupported ~anthropic_opts (opts : Ai_provider.Call_options.t) =
  List.concat
    [
      (match opts.frequency_penalty with
      | Some _ -> [ Ai_provider.Warning.Unsupported_feature { feature = "frequency_penalty"; details = None } ]
      | None -> []);
      (match opts.presence_penalty with
      | Some _ -> [ Ai_provider.Warning.Unsupported_feature { feature = "presence_penalty"; details = None } ]
      | None -> []);
      (match opts.seed with
      | Some _ -> [ Ai_provider.Warning.Unsupported_feature { feature = "seed"; details = None } ]
      | None -> []);
      (* Warn if thinking is enabled with temperature *)
      (match anthropic_opts.Anthropic_options.thinking with
      | Some t when t.Thinking.enabled && Option.is_some opts.temperature ->
        [
          Ai_provider.Warning.Unsupported_feature
            {
              feature = "temperature with thinking";
              details = Some "Anthropic does not support temperature when thinking is enabled";
            };
        ]
      | _ -> []);
    ]

(** Prepare the request body and warnings — shared by generate and stream. *)
let prepare_request ~model ~stream (opts : Ai_provider.Call_options.t) =
  let anthropic_opts =
    Anthropic_options.of_provider_options opts.provider_options
    |> Stdlib.Option.value ~default:Anthropic_options.default
  in
  let warnings = check_unsupported ~anthropic_opts opts in
  let system, remaining = Convert_prompt.extract_system opts.prompt in
  let messages = Convert_prompt.convert_messages remaining in
  let tools, tool_choice = Convert_tools.convert_tools ~tools:opts.tools ~tool_choice:opts.tool_choice in
  (* Use model-aware default for max_tokens *)
  let max_tokens =
    Some
      (match opts.max_output_tokens with
      | Some n -> n
      | None -> Model_catalog.default_max_tokens (Model_catalog.of_model_id model))
  in
  let thinking_enabled =
    match anthropic_opts.thinking with
    | Some t when t.Thinking.enabled -> true
    | Some _ | None -> false
  in
  let body =
    Anthropic_api.make_request_body ~model ~messages ?system ~tools ?tool_choice ?max_tokens
      ?temperature:opts.temperature ?top_p:opts.top_p ?top_k:opts.top_k ~stop_sequences:opts.stop_sequences
      ?thinking:anthropic_opts.thinking ~stream ()
  in
  (* Merge user headers with required beta headers — the result includes all of opts.headers
     plus a merged anthropic-beta header, so it replaces opts.headers entirely *)
  let required_betas =
    Beta_headers.required_betas ~thinking:thinking_enabled ~has_pdf:false ~tool_streaming:anthropic_opts.tool_streaming
  in
  let extra_headers = Beta_headers.merge_beta_headers ~user_headers:opts.headers ~required:required_betas in
  body, warnings, extra_headers

let create ~config ~model =
  let module M = struct
    let specification_version = "V3"
    let provider = "anthropic"
    let model_id = model

    let generate opts =
      let body, warnings, extra_headers = prepare_request ~model ~stream:false opts in
      let%lwt response = Anthropic_api.messages ~config ~body ~extra_headers ~stream:false in
      match response with
      | `Json json ->
        let result = Convert_response.parse_response json in
        Lwt.return { result with warnings = warnings @ result.warnings }
      | `Stream _ -> Lwt.fail_with "unexpected streaming response for non-streaming request"

    let stream opts =
      let body, warnings, extra_headers = prepare_request ~model ~stream:true opts in
      let%lwt response = Anthropic_api.messages ~config ~body ~extra_headers ~stream:true in
      match response with
      | `Stream line_stream ->
        let sse_events = Sse.parse_events line_stream in
        let parts = Convert_stream.transform sse_events ~warnings in
        Lwt.return { Ai_provider.Stream_result.stream = parts; warnings; raw_response = None }
      | `Json _ -> Lwt.fail_with "unexpected non-streaming response for streaming request"
  end in
  (module M : Ai_provider.Language_model.S)
