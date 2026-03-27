open Melange_json.Primitives

(* --- Typed JSON records for serialization --- *)

type text_content_part = {
  type_ : string; [@json.key "type"]
  text : string;
}
[@@deriving to_json]

type image_url_detail = { url : string } [@@deriving to_json]

type image_url_content_part = {
  type_ : string; [@json.key "type"]
  image_url : image_url_detail;
}
[@@deriving to_json]

type function_call_json = {
  name : string;
  arguments : string;
}
[@@deriving to_json]

type tool_call_json = {
  id : string;
  type_ : string; [@json.key "type"]
  function_ : function_call_json; [@json.key "function"]
}
[@@deriving to_json]

type role_content_msg = {
  role : string;
  content : string;
}
[@@deriving to_json]

type role_parts_msg = {
  role : string;
  content : Melange_json.t list;
}
[@@deriving to_json]

type assistant_msg_with_tools_json = {
  role : string;
  content : string option; [@json.option] [@json.drop_default]
  tool_calls : tool_call_json list;
}
[@@deriving to_json]

type assistant_msg_text_json = {
  role : string;
  content : string option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type tool_msg_json = {
  role : string;
  tool_call_id : string;
  content : string;
}
[@@deriving to_json]

(* --- Domain types --- *)

type openai_content_part =
  | O_text of { text : string }
  | O_image_url of { url : string }

type openai_function_call = {
  name : string;
  arguments : string;
}

type openai_tool_call = {
  id : string;
  type_ : string;
  function_ : openai_function_call;
}

type openai_message =
  | System_msg of { content : string }
  | Developer_msg of { content : string }
  | User_msg of { content : openai_content_part list }
  | Assistant_msg of {
      content : string option;
      tool_calls : openai_tool_call list;
    }
  | Tool_msg of {
      tool_call_id : string;
      content : string;
    }

(* --- Conversion logic --- *)

let file_data_to_url ~media_type (data : Ai_provider.Prompt.file_data) =
  match data with
  | Bytes b ->
    let encoded = Base64.encode_string (Bytes.to_string b) in
    Printf.sprintf "data:%s;base64,%s" media_type encoded
  | Base64 s -> Printf.sprintf "data:%s;base64,%s" media_type s
  | Url u -> u

let convert_user_part (part : Ai_provider.Prompt.user_part) : openai_content_part =
  match part with
  | Text { text; _ } -> O_text { text }
  | File { data; media_type; _ } ->
    if String.starts_with ~prefix:"image/" media_type then O_image_url { url = file_data_to_url ~media_type data }
    else O_text { text = Printf.sprintf "[file: %s]" media_type }

let convert_assistant_parts (parts : Ai_provider.Prompt.assistant_part list) : string option * openai_tool_call list =
  let text_buf = Buffer.create 256 in
  let tool_calls =
    List.fold_left
      (fun acc (part : Ai_provider.Prompt.assistant_part) ->
        match part with
        | Text { text; _ } ->
          Buffer.add_string text_buf text;
          acc
        | File _ | Reasoning _ -> acc
        | Tool_call { id; name; args; _ } ->
          { id; type_ = "function"; function_ = { name; arguments = Yojson.Basic.to_string args } } :: acc)
      [] parts
    |> List.rev
  in
  let content = if Buffer.length text_buf > 0 then Some (Buffer.contents text_buf) else None in
  content, tool_calls

let convert_tool_result (tr : Ai_provider.Prompt.tool_result) : openai_message =
  let content =
    match tr.content with
    | [] ->
      (match tr.result with
      | `String s -> s
      | json -> Yojson.Basic.to_string json)
    | parts ->
      let texts =
        List.map
          (fun (c : Ai_provider.Prompt.tool_result_content) ->
            match c with
            | Result_text s -> s
            | Result_image { data; media_type } ->
              Printf.sprintf "[image: %s, %d bytes]" media_type (String.length data))
          parts
      in
      String.concat "\n" texts
  in
  Tool_msg { tool_call_id = tr.tool_call_id; content }

let convert_messages ~system_message_mode messages =
  let warnings = ref [] in
  let result =
    List.concat_map
      (fun (msg : Ai_provider.Prompt.message) ->
        match msg with
        | System { content } ->
          (match (system_message_mode : Model_catalog.system_message_mode) with
          | System -> [ System_msg { content } ]
          | Developer -> [ Developer_msg { content } ]
          | Remove ->
            warnings :=
              Ai_provider.Warning.Unsupported_feature
                { feature = "system-messages"; details = Some "System messages are removed for this model" }
              :: !warnings;
            [])
        | User { content } -> [ User_msg { content = List.map convert_user_part content } ]
        | Assistant { content } ->
          let text, tool_calls = convert_assistant_parts content in
          [ Assistant_msg { content = text; tool_calls } ]
        | Tool { content } -> List.map convert_tool_result content)
      messages
  in
  result, List.rev !warnings

(* --- JSON serialization via derivers --- *)

let content_part_to_json = function
  | O_text { text } -> text_content_part_to_json { type_ = "text"; text }
  | O_image_url { url } -> image_url_content_part_to_json { type_ = "image_url"; image_url = { url } }

let domain_tool_call_to_json_record (tc : openai_tool_call) : tool_call_json =
  { id = tc.id; type_ = tc.type_; function_ = { name = tc.function_.name; arguments = tc.function_.arguments } }

let openai_message_to_json = function
  | System_msg { content } -> role_content_msg_to_json { role = "system"; content }
  | Developer_msg { content } -> role_content_msg_to_json { role = "developer"; content }
  | User_msg { content } ->
    (match content with
    | [ O_text { text } ] -> role_content_msg_to_json { role = "user"; content = text }
    | parts -> role_parts_msg_to_json { role = "user"; content = List.map content_part_to_json parts })
  | Assistant_msg { content; tool_calls } ->
    (match tool_calls with
    | [] -> assistant_msg_text_json_to_json { role = "assistant"; content }
    | calls ->
      assistant_msg_with_tools_json_to_json
        { role = "assistant"; content; tool_calls = List.map domain_tool_call_to_json_record calls })
  | Tool_msg { tool_call_id; content } -> tool_msg_json_to_json { role = "tool"; tool_call_id; content }
