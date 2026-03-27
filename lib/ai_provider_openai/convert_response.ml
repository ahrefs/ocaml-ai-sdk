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

type choice_message_json = {
  role : string option; [@json.default None]
  content : string option; [@json.default None]
  tool_calls : tool_call_json list; [@json.default []]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type choice_json = {
  index : int; [@json.default 0]
  message : choice_message_json;
  finish_reason : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type openai_response_json = {
  id : string option; [@json.default None]
  model : string option; [@json.default None]
  choices : choice_json list; [@json.default []]
  usage : Convert_usage.openai_usage option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

let map_finish_reason = function
  | Some "stop" -> Ai_provider.Finish_reason.Stop
  | Some "length" -> Ai_provider.Finish_reason.Length
  | Some "content_filter" -> Ai_provider.Finish_reason.Content_filter
  | Some "tool_calls" -> Ai_provider.Finish_reason.Tool_calls
  | Some "function_call" -> Ai_provider.Finish_reason.Tool_calls
  | Some other -> Ai_provider.Finish_reason.Other other
  | None -> Ai_provider.Finish_reason.Unknown

let default_usage = { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }

let parse_response json =
  let resp = openai_response_json_of_json json in
  let choice = List.nth_opt resp.choices 0 in
  let content =
    match choice with
    | None -> []
    | Some { message; _ } ->
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
      text_content @ tool_content
  in
  let finish_reason =
    match choice with
    | Some { finish_reason; _ } -> map_finish_reason finish_reason
    | None -> Ai_provider.Finish_reason.Unknown
  in
  let usage =
    match resp.usage with
    | Some u -> Convert_usage.to_usage u
    | None -> default_usage
  in
  {
    Ai_provider.Generate_result.content;
    finish_reason;
    usage;
    warnings = [];
    provider_metadata = Ai_provider.Provider_options.empty;
    request = { body = json };
    response = { id = resp.id; model = resp.model; headers = []; body = json };
  }
