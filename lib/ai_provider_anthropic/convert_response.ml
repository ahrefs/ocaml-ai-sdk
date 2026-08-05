open Melange_json.Primitives

type content_block_json = {
  type_ : string; [@json.key "type"]
  text : string option; [@json.default None]
  id : string option; [@json.default None]
  name : string option; [@json.default None]
  input : Melange_json.t option; [@json.default None]
  thinking : string option; [@json.default None]
  signature : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving json]

type anthropic_response_json = {
  id : string option; [@json.default None]
  model : string option; [@json.default None]
  content : content_block_json list; [@json.default []]
  stop_reason : string option; [@json.default None]
  usage : Convert_usage.anthropic_usage;
}
[@@json.allow_extra_fields] [@@deriving json]

let map_stop_reason = function
  | Some "end_turn" -> Ai_provider.Finish_reason.Stop
  | Some "max_tokens" -> Ai_provider.Finish_reason.Length
  | Some "tool_use" -> Ai_provider.Finish_reason.Tool_calls
  | Some "stop_sequence" -> Ai_provider.Finish_reason.Stop
  | Some other -> Ai_provider.Finish_reason.Other other
  | None -> Ai_provider.Finish_reason.Unknown

let reasoning_provider_options = function
  | None -> Ai_provider.Provider_options.empty
  | Some signature ->
    Ai_provider.Provider_options.of_provider_metadata
      (`Assoc [ "anthropic", `Assoc [ "signature", `String signature ] ])

let parse_content_block (block : content_block_json) =
  match block.type_ with
  | "text" -> Option.map (fun text -> Ai_provider.Content.Text { text }) block.text
  | "tool_use" ->
    (match block.id, block.name, block.input with
    | Some id, Some name, Some input ->
      Some
        (Ai_provider.Content.Tool_call
           { tool_call_type = "function"; tool_call_id = id; tool_name = name; args = Yojson.Basic.to_string input })
    | _ -> None)
  | "thinking" ->
    Option.map
      (fun text ->
        Ai_provider.Content.Reasoning
          { text; signature = block.signature; provider_options = reasoning_provider_options block.signature })
      block.thinking
  | _ -> None

let parse_response json =
  let resp = anthropic_response_json_of_json json in
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
