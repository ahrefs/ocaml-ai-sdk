open Melange_json.Primitives

type image_source =
  | Base64_image of {
      media_type : string;
      data : string;
    }
  | Url_image of { url : string }

type document_source =
  | Base64_document of {
      media_type : string;
      data : string;
    }

type anthropic_tool_result_content =
  | Tool_text of string
  | Tool_image of { source : image_source }

type anthropic_content =
  | A_text of {
      text : string;
      cache_control : Cache_control.t option;
    }
  | A_image of {
      source : image_source;
      cache_control : Cache_control.t option;
    }
  | A_document of {
      source : document_source;
      cache_control : Cache_control.t option;
    }
  | A_tool_use of {
      id : string;
      name : string;
      input : Yojson.Basic.t;
    }
  | A_tool_result of {
      tool_use_id : string;
      content : anthropic_tool_result_content list;
      is_error : bool;
    }
  | A_thinking of {
      thinking : string;
      signature : string;
    }

type anthropic_message = {
  role : [ `User | `Assistant ];
  content : anthropic_content list;
}

(* Extract system messages and return the rest *)
let extract_system messages =
  let system_parts, rest =
    List.partition_map
      (fun (msg : Ai_provider.Prompt.message) ->
        match msg with
        | System { content } -> Left content
        | User _ | Assistant _ | Tool _ -> Right msg)
      messages
  in
  let system =
    match system_parts with
    | [] -> None
    | parts -> Some (String.concat "\n" parts)
  in
  system, rest

(* Get cache control from provider options *)
let get_cc po = Cache_control_options.get_cache_control po

(* Convert file_data to image source *)
let file_data_to_image_source ~media_type (data : Ai_provider.Prompt.file_data) =
  match data with
  | Bytes b -> Base64_image { media_type; data = Base64.encode_string (Bytes.to_string b) }
  | Base64 s -> Base64_image { media_type; data = s }
  | Url u -> Url_image { url = u }

(* Convert a user part to anthropic content *)
let convert_user_part (part : Ai_provider.Prompt.user_part) : anthropic_content =
  match part with
  | Text { text; provider_options } -> A_text { text; cache_control = get_cc provider_options }
  | File { data; media_type; provider_options; _ } ->
    if String.starts_with ~prefix:"image/" media_type then
      A_image { source = file_data_to_image_source ~media_type data; cache_control = get_cc provider_options }
    else
      A_document
        {
          source =
            (match data with
            | Bytes b -> Base64_document { media_type; data = Base64.encode_string (Bytes.to_string b) }
            | Base64 s -> Base64_document { media_type; data = s }
            | Url u -> invalid_arg (Printf.sprintf "Anthropic documents must be base64-encoded, got URL: %s" u));
          cache_control = get_cc provider_options;
        }

(* Convert an assistant part to anthropic content *)
let convert_assistant_part (part : Ai_provider.Prompt.assistant_part) : anthropic_content =
  match part with
  | Text { text; provider_options } -> A_text { text; cache_control = get_cc provider_options }
  | File { data; media_type; provider_options; _ } ->
    A_image { source = file_data_to_image_source ~media_type data; cache_control = get_cc provider_options }
  | Reasoning { text; provider_options = _ } ->
    (* Reasoning parts become thinking blocks. Signature is not available
       in the prompt (it comes from responses), so we use empty string. *)
    A_thinking { thinking = text; signature = "" }
  | Tool_call { id; name; args; provider_options = _ } -> A_tool_use { id; name; input = args }

(* Convert a tool result to anthropic content *)
let convert_tool_result (tr : Ai_provider.Prompt.tool_result) : anthropic_content =
  let content =
    List.map
      (fun (c : Ai_provider.Prompt.tool_result_content) ->
        match c with
        | Result_text s -> Tool_text s
        | Result_image { data; media_type } -> Tool_image { source = Base64_image { media_type; data } })
      tr.content
  in
  (* If no explicit content, use the result as text *)
  let content =
    match content with
    | [] ->
      (match tr.result with
      | `String s -> [ Tool_text s ]
      | json -> [ Tool_text (Yojson.Basic.to_string json) ])
    | _ -> content
  in
  A_tool_result { tool_use_id = tr.tool_call_id; content; is_error = tr.is_error }

(* Convert a single SDK message to role + content parts *)
let convert_single_message (msg : Ai_provider.Prompt.message) : ([ `User | `Assistant ] * anthropic_content list) option
    =
  match msg with
  | System _ -> None (* already extracted *)
  | User { content } -> Some (`User, List.map convert_user_part content)
  | Assistant { content } -> Some (`Assistant, List.map convert_assistant_part content)
  | Tool { content } -> Some (`User, List.map convert_tool_result content)

(* Group messages to ensure alternating user/assistant roles.
   Consecutive messages with the same role are merged. *)
let role_equal (a : [ `User | `Assistant ]) (b : [ `User | `Assistant ]) =
  match a, b with
  | `User, `User | `Assistant, `Assistant -> true
  | `User, `Assistant | `Assistant, `User -> false

let group_messages (msgs : ([ `User | `Assistant ] * anthropic_content list) list) : anthropic_message list =
  let rec go acc = function
    | [] -> List.rev acc
    | (role, content) :: rest ->
    match acc with
    | { role = prev_role; content = prev_content } :: acc_rest when role_equal prev_role role ->
      go ({ role; content = prev_content @ content } :: acc_rest) rest
    | _ -> go ({ role; content } :: acc) rest
  in
  go [] msgs

let convert_messages messages =
  let role_content_pairs = List.filter_map convert_single_message messages in
  group_messages role_content_pairs

(* JSON serialization — typed records for each content shape *)

type cc = Cache_control.t

let cc_to_json (cc : cc) = Cache_control.breakpoint_to_json cc.cache_type

type image_source_base64_json = {
  type_ : string; [@json.key "type"]
  media_type : string;
  data : string;
}
[@@deriving to_json]

type image_source_url_json = {
  type_ : string; [@json.key "type"]
  url : string;
}
[@@deriving to_json]

let image_source_to_json = function
  | Base64_image { media_type; data } -> image_source_base64_json_to_json { type_ = "base64"; media_type; data }
  | Url_image { url } -> image_source_url_json_to_json { type_ = "url"; url }

type text_content_json = {
  type_ : string; [@json.key "type"]
  text : string;
  cache_control : cc option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type source_content_json = {
  type_ : string; [@json.key "type"]
  source : Melange_json.t;
  cache_control : cc option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type tool_use_json = {
  type_ : string; [@json.key "type"]
  id : string;
  name : string;
  input : Melange_json.t;
}
[@@deriving to_json]

type tool_result_json = {
  type_ : string; [@json.key "type"]
  tool_use_id : string;
  content : Melange_json.t list;
  is_error : bool;
}
[@@deriving to_json]

type thinking_json = {
  type_ : string; [@json.key "type"]
  thinking : string;
  signature : string;
}
[@@deriving to_json]

let tool_result_content_to_json = function
  | Tool_text s -> text_content_json_to_json { type_ = "text"; text = s; cache_control = None }
  | Tool_image { source } ->
    source_content_json_to_json { type_ = "image"; source = image_source_to_json source; cache_control = None }

let anthropic_content_to_json = function
  | A_text { text; cache_control } -> text_content_json_to_json { type_ = "text"; text; cache_control }
  | A_image { source; cache_control } ->
    source_content_json_to_json { type_ = "image"; source = image_source_to_json source; cache_control }
  | A_document { source; cache_control } ->
    let (Base64_document { media_type; data }) = source in
    let source_json = image_source_base64_json_to_json { type_ = "base64"; media_type; data } in
    source_content_json_to_json { type_ = "document"; source = source_json; cache_control }
  | A_tool_use { id; name; input } -> tool_use_json_to_json { type_ = "tool_use"; id; name; input }
  | A_tool_result { tool_use_id; content; is_error } ->
    let content_json = List.map tool_result_content_to_json content in
    tool_result_json_to_json { type_ = "tool_result"; tool_use_id; content = content_json; is_error }
  | A_thinking { thinking; signature } -> thinking_json_to_json { type_ = "thinking"; thinking; signature }

type message_json = {
  role : string;
  content : Melange_json.t list;
}
[@@deriving to_json]

let anthropic_message_to_json ({ role; content } : anthropic_message) =
  let role_str =
    match role with
    | `User -> "user"
    | `Assistant -> "assistant"
  in
  message_json_to_json { role = role_str; content = List.map anthropic_content_to_json content }
