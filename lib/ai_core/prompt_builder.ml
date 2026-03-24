let po = Ai_provider.Provider_options.empty

let messages_of_prompt ?system ~prompt () =
  let system_msgs =
    match system with
    | Some s -> [ Ai_provider.Prompt.System { content = s } ]
    | None -> []
  in
  system_msgs @ [ Ai_provider.Prompt.User { content = [ Text { text = prompt; provider_options = po } ] } ]

let messages_of_string_messages ?system ~messages () =
  let system_msgs =
    match system with
    | Some s -> [ Ai_provider.Prompt.System { content = s } ]
    | None -> []
  in
  let converted =
    List.filter_map
      (fun (role, content) ->
        match role with
        | "system" -> Some (Ai_provider.Prompt.System { content })
        | "user" -> Some (Ai_provider.Prompt.User { content = [ Text { text = content; provider_options = po } ] })
        | "assistant" ->
          Some (Ai_provider.Prompt.Assistant { content = [ Text { text = content; provider_options = po } ] })
        | _ -> None)
      messages
  in
  system_msgs @ converted

let append_assistant_and_tool_results ~messages ~assistant_content ~tool_results =
  let assistant_parts =
    List.map
      (fun (c : Ai_provider.Content.t) ->
        match c with
        | Text { text } -> Ai_provider.Prompt.Text { text; provider_options = po }
        | Tool_call { tool_call_id; tool_name; args; _ } ->
          Ai_provider.Prompt.Tool_call
            { id = tool_call_id; name = tool_name; args = Yojson.Safe.from_string args; provider_options = po }
        | Reasoning { text; _ } -> Ai_provider.Prompt.Reasoning { text; provider_options = po }
        | File _ -> Ai_provider.Prompt.Text { text = "[file]"; provider_options = po })
      assistant_content
  in
  let tool_result_parts =
    List.map
      (fun (tr : Generate_text_result.tool_result) ->
        {
          Ai_provider.Prompt.tool_call_id = tr.tool_call_id;
          tool_name = tr.tool_name;
          result = tr.result;
          is_error = tr.is_error;
          content = [ Result_text (Yojson.Safe.to_string tr.result) ];
          provider_options = po;
        })
      tool_results
  in
  messages
  @ [ Ai_provider.Prompt.Assistant { content = assistant_parts } ]
  @
  match tool_result_parts with
  | [] -> []
  | parts -> [ Ai_provider.Prompt.Tool { content = parts } ]

let resolve_messages ?system ?prompt ?messages () =
  let base =
    match prompt, messages with
    | Some p, None -> [ Ai_provider.Prompt.User { content = [ Text { text = p; provider_options = po } ] } ]
    | None, Some msgs -> msgs
    | Some _, Some _ -> failwith "Cannot provide both ~prompt and ~messages"
    | None, None -> failwith "Must provide either ~prompt or ~messages"
  in
  match system with
  | Some s -> Ai_provider.Prompt.System { content = s } :: base
  | None -> base

let make_call_options ~messages ~tools ?tool_choice ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed
  ?provider_options ?headers () =
  {
    Ai_provider.Call_options.prompt = messages;
    mode = Regular;
    tools;
    tool_choice;
    max_output_tokens;
    temperature;
    top_p;
    top_k;
    stop_sequences = Option.value ~default:[] stop_sequences;
    seed;
    frequency_penalty = None;
    presence_penalty = None;
    provider_options = Option.value ~default:Ai_provider.Provider_options.empty provider_options;
    headers = Option.value ~default:[] headers;
    abort_signal = None;
  }

let tools_to_provider tools =
  List.map
    (fun (name, (tool : Core_tool.t)) ->
      { Ai_provider.Tool.name; description = tool.description; parameters = tool.parameters })
    tools
