open Melange_json.Primitives

type function_call_json = {
  name : string; [@json.default ""]
  arguments : string; [@json.default ""]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type tool_call_json = {
  id : string; [@json.default ""]
  type_ : string; [@json.key "type"] [@json.default "function"]
  function_ : function_call_json; [@json.key "function"]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type reasoning_detail_json = {
  type_ : string; [@json.key "type"] [@json.default ""]
  text : string option; [@json.default None]
  signature : string option; [@json.default None]
  data : string option; [@json.default None]
  summary : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type choice_message_json = {
  role : string option; [@json.default None]
  content : string option; [@json.default None]
  reasoning : string option; [@json.default None]
  reasoning_details : reasoning_detail_json list; [@json.default []]
  tool_calls : tool_call_json list; [@json.default []]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type choice_json = {
  index : int; [@json.default 0]
  message : choice_message_json;
  finish_reason : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type openrouter_response_json = {
  id : string option; [@json.default None]
  model : string option; [@json.default None]
  provider : string option; [@json.default None]
  choices : choice_json list; [@json.default []]
  usage : Convert_usage.openrouter_usage option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type _ Ai_provider.Provider_options.key +=
  | Openrouter_provider : string Ai_provider.Provider_options.key

let map_finish_reason = function
  | Some "stop" -> Ai_provider.Finish_reason.Stop
  | Some "length" -> Ai_provider.Finish_reason.Length
  | Some "content_filter" -> Ai_provider.Finish_reason.Content_filter
  | Some "tool_calls" -> Ai_provider.Finish_reason.Tool_calls
  | Some "function_call" -> Ai_provider.Finish_reason.Tool_calls
  | Some other -> Ai_provider.Finish_reason.Other other
  | None -> Ai_provider.Finish_reason.Unknown

let default_usage = { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }

let convert_reasoning_detail (d : reasoning_detail_json) =
  match d.type_ with
  | "reasoning.text" ->
    (match d.text with
    | Some text when String.length text > 0 ->
      Some
        (Ai_provider.Content.Reasoning
           { text; signature = d.signature; provider_options = Ai_provider.Provider_options.empty })
    | Some _ | None -> None)
  | "reasoning.encrypted" ->
    (match d.data with
    | Some data when String.length data > 0 ->
      Some
        (Ai_provider.Content.Reasoning
           { text = "[REDACTED]"; signature = None; provider_options = Ai_provider.Provider_options.empty })
    | Some _ | None -> None)
  | "reasoning.summary" ->
    (match d.summary with
    | Some summary when String.length summary > 0 ->
      Some
        (Ai_provider.Content.Reasoning
           { text = summary; signature = None; provider_options = Ai_provider.Provider_options.empty })
    | Some _ | None -> None)
  | _ -> None

let has_encrypted_reasoning details =
  List.exists
    (fun (d : reasoning_detail_json) ->
      match d.type_, d.data with
      | "reasoning.encrypted", Some data when String.length data > 0 -> true
      | _ -> false)
    details

let override_finish_reason ~has_tool_calls ~has_encrypted (finish_reason : Ai_provider.Finish_reason.t) =
  match has_tool_calls, has_encrypted, finish_reason with
  | true, true, Stop -> Ai_provider.Finish_reason.Tool_calls
  | true, _, Other _ -> Ai_provider.Finish_reason.Tool_calls
  | _ -> finish_reason

let parse_response json =
  let resp = openrouter_response_json_of_json json in
  let choice = List.nth_opt resp.choices 0 in
  let content =
    match choice with
    | None -> []
    | Some { message; _ } ->
      let reasoning_content =
        match message.reasoning_details with
        | _ :: _ as details -> List.filter_map convert_reasoning_detail details
        | [] ->
          (match message.reasoning with
          | Some text when String.length text > 0 ->
            [ Ai_provider.Content.Reasoning
                { text; signature = None; provider_options = Ai_provider.Provider_options.empty }
            ]
          | Some _ | None -> [])
      in
      let text_content =
        match message.content with
        | Some text when String.length text > 0 -> [ Ai_provider.Content.Text { text } ]
        | Some _ | None -> []
      in
      let tool_content =
        List.map
          (fun (tc : tool_call_json) ->
            Ai_provider.Content.Tool_call
              {
                tool_call_type = "function";
                tool_call_id = tc.id;
                tool_name = tc.function_.name;
                args = tc.function_.arguments;
              })
          message.tool_calls
      in
      reasoning_content @ text_content @ tool_content
  in
  let has_tool_calls =
    match choice with
    | Some { message; _ } -> message.tool_calls <> []
    | None -> false
  in
  let has_encrypted =
    match choice with
    | Some { message; _ } -> has_encrypted_reasoning message.reasoning_details
    | None -> false
  in
  let finish_reason =
    match choice with
    | Some { finish_reason; _ } -> map_finish_reason finish_reason
    | None -> Ai_provider.Finish_reason.Unknown
  in
  let finish_reason = override_finish_reason ~has_tool_calls ~has_encrypted finish_reason in
  let usage, provider_metadata =
    match resp.usage with
    | Some u ->
      let metadata = Convert_usage.to_metadata u in
      let provider_metadata =
        Ai_provider.Provider_options.set Convert_usage.Openrouter_usage metadata Ai_provider.Provider_options.empty
      in
      Convert_usage.to_usage u, provider_metadata
    | None -> default_usage, Ai_provider.Provider_options.empty
  in
  let provider_metadata =
    match resp.provider with
    | Some p -> Ai_provider.Provider_options.set Openrouter_provider p provider_metadata
    | None -> provider_metadata
  in
  {
    Ai_provider.Generate_result.content;
    finish_reason;
    usage;
    warnings = [];
    provider_metadata;
    request = { body = json };
    response = { id = resp.id; model = resp.model; headers = []; body = json };
  }
