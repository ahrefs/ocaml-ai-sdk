let map_stop_reason = function
  | Some "end_turn" -> Ai_provider.Finish_reason.Stop
  | Some "max_tokens" -> Ai_provider.Finish_reason.Length
  | Some "tool_use" -> Ai_provider.Finish_reason.Tool_calls
  | Some "stop_sequence" -> Ai_provider.Finish_reason.Stop
  | Some other -> Ai_provider.Finish_reason.Other other
  | None -> Ai_provider.Finish_reason.Unknown

let parse_content_block json =
  let open Yojson.Safe.Util in
  let block_type = member "type" json |> to_string in
  match block_type with
  | "text" ->
    let text = member "text" json |> to_string in
    Some (Ai_provider.Content.Text { text })
  | "tool_use" ->
    let id = member "id" json |> to_string in
    let name = member "name" json |> to_string in
    let input = member "input" json in
    Some
      (Ai_provider.Content.Tool_call
         { tool_call_type = "function"; tool_call_id = id; tool_name = name; args = Yojson.Safe.to_string input })
  | "thinking" ->
    let text = member "thinking" json |> to_string in
    let signature = try Some (member "signature" json |> to_string) with Type_error _ -> None in
    Some (Ai_provider.Content.Reasoning { text; signature; provider_options = Ai_provider.Provider_options.empty })
  | _ -> None

let parse_response json =
  let open Yojson.Safe.Util in
  let id = try Some (member "id" json |> to_string) with Type_error _ -> None in
  let model = try Some (member "model" json |> to_string) with Type_error _ -> None in
  let content_json = member "content" json |> to_list in
  let content = List.filter_map parse_content_block content_json in
  let stop_reason = try Some (member "stop_reason" json |> to_string) with Type_error _ -> None in
  let usage_json = member "usage" json in
  let usage =
    match Convert_usage.anthropic_usage_of_yojson usage_json with
    | Ok u -> u
    | Error _ ->
      { Convert_usage.input_tokens = 0; output_tokens = 0; cache_read_input_tokens = None; cache_creation_input_tokens = None }
  in
  {
    Ai_provider.Generate_result.content;
    finish_reason = map_stop_reason stop_reason;
    usage = Convert_usage.to_usage usage;
    warnings = [];
    provider_metadata = Convert_usage.to_provider_metadata usage;
    request = { body = json };
    response = { id; model; headers = []; body = json };
  }
