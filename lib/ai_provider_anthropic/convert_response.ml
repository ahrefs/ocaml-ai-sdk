type content_block_json = {
  type_ : string; [@key "type"]
  text : string option; [@default None]
  id : string option; [@default None]
  name : string option; [@default None]
  input : Yojson.Safe.t option; [@default None]
  thinking : string option; [@default None]
  signature : string option; [@default None]
}
[@@deriving of_yojson { strict = false }]

type anthropic_response_json = {
  id : string option; [@default None]
  model : string option; [@default None]
  content : content_block_json list; [@default []]
  stop_reason : string option; [@default None]
  usage : Convert_usage.anthropic_usage;
}
[@@deriving of_yojson { strict = false }]

let map_stop_reason = function
  | Some "end_turn" -> Ai_provider.Finish_reason.Stop
  | Some "max_tokens" -> Ai_provider.Finish_reason.Length
  | Some "tool_use" -> Ai_provider.Finish_reason.Tool_calls
  | Some "stop_sequence" -> Ai_provider.Finish_reason.Stop
  | Some other -> Ai_provider.Finish_reason.Other other
  | None -> Ai_provider.Finish_reason.Unknown

let parse_content_block (block : content_block_json) =
  match block.type_ with
  | "text" -> Option.map (fun text -> Ai_provider.Content.Text { text }) block.text
  | "tool_use" ->
    (match block.id, block.name, block.input with
    | Some id, Some name, Some input ->
      Some
        (Ai_provider.Content.Tool_call
           { tool_call_type = "function"; tool_call_id = id; tool_name = name; args = Yojson.Safe.to_string input })
    | _ -> None)
  | "thinking" ->
    Option.map
      (fun text ->
        Ai_provider.Content.Reasoning
          { text; signature = block.signature; provider_options = Ai_provider.Provider_options.empty })
      block.thinking
  | _ -> None

let parse_response json =
  match anthropic_response_json_of_yojson json with
  | Ok resp ->
    let content = List.filter_map parse_content_block resp.content in
    {
      Ai_provider.Generate_result.content;
      finish_reason = map_stop_reason resp.stop_reason;
      usage = Convert_usage.to_usage resp.usage;
      warnings = [];
      provider_metadata = Convert_usage.to_provider_metadata resp.usage;
      request = { body = json };
      response = { id = resp.id; model = resp.model; headers = []; body = json };
    }
  | Error msg -> failwith (Printf.sprintf "Failed to parse Anthropic response: %s" msg)
