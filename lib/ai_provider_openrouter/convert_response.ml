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

type annotation_json = {
  type_ : string; [@json.key "type"] [@json.default ""]
  url : string option; [@json.default None]
  title : string option; [@json.default None]
  start_index : int option; [@json.default None]
  end_index : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type image_json = { url : string } [@@json.allow_extra_fields] [@@deriving of_json]

type choice_message_json = {
  role : string option; [@json.default None]
  content : string option; [@json.default None]
  reasoning : string option; [@json.default None]
  reasoning_details : reasoning_detail_json list; [@json.default []]
  tool_calls : tool_call_json list; [@json.default []]
  annotations : annotation_json list; [@json.default []]
  images : image_json list; [@json.default []]
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
  | Openrouter_reasoning_details : reasoning_detail_json list Ai_provider.Provider_options.key

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
    (* Encrypted reasoning is an opaque blob for multi-turn roundtripping.
       It is preserved in response-level providerMetadata and does not
       produce a visible reasoning content part (matches upstream). *)
    None
  | "reasoning.summary" ->
    (match d.summary with
    | Some summary when String.length summary > 0 ->
      Some
        (Ai_provider.Content.Reasoning
           { text = summary; signature = None; provider_options = Ai_provider.Provider_options.empty })
    | Some _ | None -> None)
  | _ -> None

let convert_annotation ~index (a : annotation_json) =
  match a.type_ with
  | "url_citation" ->
    (match a.url with
    | Some url ->
      let id = Printf.sprintf "source-%d" index in
      Some
        (Ai_provider.Content.Source
           { source_type = "url"; id; url; title = a.title; provider_options = Ai_provider.Provider_options.empty })
    | None -> None)
  | _ -> None

let convert_image (img : image_json) =
  let url = img.url in
  if String.starts_with ~prefix:"data:" url then (
    match String.index_opt url ',' with
    | Some comma_pos ->
      let header = String.sub url 5 (comma_pos - 5) in
      let media_type =
        match String.index_opt header ';' with
        | Some semi -> String.sub header 0 semi
        | None -> header
      in
      let b64_data = String.sub url (comma_pos + 1) (String.length url - comma_pos - 1) in
      Some (Ai_provider.Content.File { data = Bytes.of_string b64_data; media_type })
    | None -> None)
  else Some (Ai_provider.Content.File { data = Bytes.of_string url; media_type = "image/png" })

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
        match message.reasoning with
        | Some text when String.length text > 0 ->
          [
            Ai_provider.Content.Reasoning
              { text; signature = None; provider_options = Ai_provider.Provider_options.empty };
          ]
        | Some _ | None -> []
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
      let source_content =
        message.annotations |> List.mapi (fun i a -> convert_annotation ~index:i a) |> List.filter_map Fun.id
      in
      let image_content = List.filter_map convert_image message.images in
      reasoning_content @ text_content @ tool_content @ source_content @ image_content
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
  (* Preserve raw reasoning_details for multi-turn roundtripping (encrypted reasoning) *)
  let provider_metadata =
    match choice with
    | Some { message = { reasoning_details = _ :: _ as details; _ }; _ } ->
      Ai_provider.Provider_options.set Openrouter_reasoning_details details provider_metadata
    | Some _ | None -> provider_metadata
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
