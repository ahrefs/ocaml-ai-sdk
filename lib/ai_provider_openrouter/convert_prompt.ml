open Melange_json.Primitives

(* --- Typed JSON records for serialization ---

   These mirror the JSON shapes emitted by upstream
   [src/chat/convert-to-openrouter-chat-messages.ts]. Each optional
   [cache_control] field is serialized with [@json.option] [@json.drop_default]
   so the absence path produces byte-equivalent output to a non-caching
   request (except for the documented system-message shape change in
   plan §4.2 / §11). *)

type text_part_json = {
  type_ : string; [@json.key "type"]
  text : string;
  cache_control : Melange_json.t option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type image_url_detail = { url : string } [@@deriving to_json]

type image_url_part_json = {
  type_ : string; [@json.key "type"]
  image_url : image_url_detail;
  cache_control : Melange_json.t option; [@json.option] [@json.drop_default]
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

(* System message always uses array-of-text-parts form (upstream §4.2). *)
type system_msg_json = {
  role : string;
  content : text_part_json list;
}
[@@deriving to_json]

(* Developer mode kept for parity with OpenAI converter's
   system_message_mode=Developer; upstream OpenRouter does not emit
   this role. *)
type developer_msg_json = {
  role : string;
  content : string;
}
[@@deriving to_json]

type user_msg_string_json = {
  role : string;
  content : string;
}
[@@deriving to_json]

type user_msg_parts_json = {
  role : string;
  content : Melange_json.t list;
}
[@@deriving to_json]

type assistant_msg_with_tools_json = {
  role : string;
  content : string option; [@json.option] [@json.drop_default]
  tool_calls : tool_call_json list;
  cache_control : Melange_json.t option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type assistant_msg_text_json = {
  role : string;
  content : string option; [@json.option] [@json.drop_default]
  cache_control : Melange_json.t option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type tool_msg_json = {
  role : string;
  tool_call_id : string;
  content : string;
  name : string;
  cache_control : Melange_json.t option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

(* --- Domain types --- *)

type or_content_part =
  | Or_text of {
      text : string;
      cache_control : Cache_control.t option;
    }
  | Or_image_url of {
      url : string;
      cache_control : Cache_control.t option;
    }

type or_function_call = {
  name : string;
  arguments : string;
}

type or_tool_call = {
  id : string;
  type_ : string;
  function_ : or_function_call;
}

type openrouter_message =
  | System_msg of {
      content : string;
      cache_control : Cache_control.t option;
    }
  | Developer_msg of { content : string }
  | User_msg_single_text of {
      text : string;
      cache_control : Cache_control.t option;
    }
  | User_msg_parts of { parts : or_content_part list }
  | Assistant_msg of {
      content : string option;
      tool_calls : or_tool_call list;
      cache_control : Cache_control.t option;
    }
  | Tool_msg of {
      tool_call_id : string;
      tool_name : string;
      content : string;
      cache_control : Cache_control.t option;
    }

(* --- Helpers --- *)

let file_data_to_url ~media_type (data : Ai_provider.Prompt.file_data) =
  match data with
  | Bytes b ->
    let encoded = Base64.encode_string (Bytes.to_string b) in
    Printf.sprintf "data:%s;base64,%s" media_type encoded
  | Base64 s -> Printf.sprintf "data:%s;base64,%s" media_type s
  | Url u -> u

let cache_control_json (cc : Cache_control.t option) : Melange_json.t option = Option.map Cache_control.to_json cc

(* --- User message conversion --- *)

(* Find the index of the last text part for falling-through message-level
   cache control. Returns -1 if no text part exists. *)
let last_text_part_index (parts : Ai_provider.Prompt.user_part list) : int =
  let len = List.length parts in
  let arr = Array.of_list parts in
  let rec loop i =
    match i < 0 with
    | true -> -1
    | false ->
    match arr.(i) with
    | Ai_provider.Prompt.Text _ -> i
    | _ -> loop (i - 1)
  in
  loop (len - 1)

(* Convert a single user content part to a domain [or_content_part].
   [message_cc] is the message-level cache control resolved against
   the message's [provider_options]. [is_last_text] flags whether
   this is the last text part (the only one to inherit [message_cc]
   when its own provider_options has no cache control). *)
let convert_user_part_multi ~message_cc ~is_last_text (part : Ai_provider.Prompt.user_part) : or_content_part =
  match part with
  | Text { text; provider_options } ->
    let part_cc = Cache_control_options.get_cache_control provider_options in
    let cache_control =
      match part_cc, is_last_text with
      | Some _, _ -> part_cc
      | None, true -> message_cc
      | None, false -> None
    in
    Or_text { text; cache_control }
  | File { data; media_type; provider_options; _ } ->
    (* Non-text parts: only per-part cache control (no fallback to msg level). *)
    let part_cc = Cache_control_options.get_cache_control provider_options in
    (match String.starts_with ~prefix:"image/" media_type with
    | true -> Or_image_url { url = file_data_to_url ~media_type data; cache_control = part_cc }
    | false ->
      (* Mirror the OpenAI fork's degenerate fallback: emit a placeholder
         text part. Upstream OpenRouter handles non-image files with
         dedicated file/audio/video shapes, but those are out of scope
         for this fork (matches today's behavior). *)
      Or_text { text = Printf.sprintf "[file: %s]" media_type; cache_control = part_cc })

(* Convert a user message: pick single-text shape when applicable. *)
let convert_user_message ~message_po (parts : Ai_provider.Prompt.user_part list) : openrouter_message =
  let message_cc = Cache_control_options.get_cache_control message_po in
  match parts with
  | [ Text { text; provider_options = part_po } ] ->
    (* Single-text path: message_cc falls back to part_cc.
       Upstream: getCacheControl(providerOptions) ?? getCacheControl(content[0].providerOptions). *)
    let cache_control =
      match message_cc with
      | Some _ -> message_cc
      | None -> Cache_control_options.get_cache_control part_po
    in
    (match cache_control with
    | None -> User_msg_single_text { text; cache_control = None }
    | Some _ ->
      (* Emit one-element array form. *)
      User_msg_parts { parts = [ Or_text { text; cache_control } ] })
  | user_parts ->
    let last_idx = last_text_part_index user_parts in
    let converted =
      List.mapi
        (fun i (part : Ai_provider.Prompt.user_part) ->
          let is_last_text =
            match part with
            | Text _ -> i = last_idx
            | _ -> false
          in
          convert_user_part_multi ~message_cc ~is_last_text part)
        user_parts
    in
    User_msg_parts { parts = converted }

(* --- Assistant message conversion --- *)

let convert_assistant_parts (parts : Ai_provider.Prompt.assistant_part list) :
  string option * or_tool_call list * Cache_control.t option =
  let text_buf = Buffer.create 256 in
  let cache_control = ref None in
  let take_cache_control provider_options =
    match !cache_control with
    | Some _ -> ()
    | None -> cache_control := Cache_control_options.get_cache_control provider_options
  in
  let tool_calls_rev =
    List.fold_left
      (fun acc (part : Ai_provider.Prompt.assistant_part) ->
        match part with
        | Text { text; provider_options } ->
          take_cache_control provider_options;
          Buffer.add_string text_buf text;
          acc
        | File { provider_options; _ } | Reasoning { provider_options; _ } ->
          take_cache_control provider_options;
          acc
        | Tool_call { id; name; args; provider_options } ->
          take_cache_control provider_options;
          { id; type_ = "function"; function_ = { name; arguments = Yojson.Basic.to_string args } } :: acc)
      [] parts
  in
  let tool_calls = List.rev tool_calls_rev in
  let content =
    match Buffer.length text_buf > 0 with
    | true -> Some (Buffer.contents text_buf)
    | false -> None
  in
  content, tool_calls, !cache_control

(* --- Tool message conversion --- *)

let tool_result_content_to_string (tr : Ai_provider.Prompt.tool_result) : string =
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
          | Result_image { data; media_type } -> Printf.sprintf "[image: %s, %d bytes]" media_type (String.length data))
        parts
    in
    String.concat "\n" texts

(* Emit one [role: tool] message per tool_result. Cache control resolution
   mirrors upstream: getCacheControl(message_po) ?? getCacheControl(result_po). *)
let convert_tool_result ~message_cc (tr : Ai_provider.Prompt.tool_result) : openrouter_message =
  let cache_control =
    match message_cc with
    | Some _ -> message_cc
    | None -> Cache_control_options.get_cache_control tr.provider_options
  in
  Tool_msg
    {
      tool_call_id = tr.tool_call_id;
      tool_name = tr.tool_name;
      content = tool_result_content_to_string tr;
      cache_control;
    }

(* --- Top-level dispatch --- *)

let convert_messages ~system_message_mode messages =
  let warnings = ref [] in
  let result =
    List.concat_map
      (fun (msg : Ai_provider.Prompt.message) ->
        match msg with
        | System { content; provider_options } ->
          let cache_control = Cache_control_options.get_cache_control provider_options in
          (match (system_message_mode : Model_catalog.system_message_mode) with
          | System -> [ System_msg { content; cache_control } ]
          | Developer ->
            (* Developer mode preserves the OpenAI behavior; cache_control is
               not surfaced here because upstream OpenRouter doesn't emit a
               developer role at all. *)
            [ Developer_msg { content } ]
          | Remove ->
            warnings :=
              Ai_provider.Warning.Unsupported_feature
                { feature = "system-messages"; details = Some "System messages are removed for this model" }
              :: !warnings;
            [])
        | User { content } -> [ convert_user_message ~message_po:Ai_provider.Provider_options.empty content ]
        | Assistant { content } ->
          let text, tool_calls, cache_control = convert_assistant_parts content in
          (* The Prompt.Assistant variant has no provider_options field today
             (see lib/ai_provider/prompt.mli). Until that surface is added,
             hoist the first assistant-part cache marker to the root
             assistant cache_control field, which is the OpenRouter wire
             placement for assistant messages. *)
          [ Assistant_msg { content = text; tool_calls; cache_control } ]
        | Tool { content } ->
          (* Tool message has no message-level provider_options field today;
             cache control resolution therefore falls through to each
             tool_result's own provider_options (matches upstream's
             [message_cc ?? result_cc] when message_cc is None). *)
          List.map (convert_tool_result ~message_cc:None) content)
      messages
  in
  result, List.rev !warnings

(* --- JSON serialization via derivers --- *)

let content_part_to_json = function
  | Or_text { text; cache_control } ->
    text_part_json_to_json { type_ = "text"; text; cache_control = cache_control_json cache_control }
  | Or_image_url { url; cache_control } ->
    image_url_part_json_to_json
      { type_ = "image_url"; image_url = { url }; cache_control = cache_control_json cache_control }

let domain_tool_call_to_json_record (tc : or_tool_call) : tool_call_json =
  { id = tc.id; type_ = tc.type_; function_ = { name = tc.function_.name; arguments = tc.function_.arguments } }

let openrouter_message_to_json = function
  | System_msg { content; cache_control } ->
    (* Always array form (plan §4.2 / upstream switch case 'system'). *)
    system_msg_json_to_json
      {
        role = "system";
        content = [ { type_ = "text"; text = content; cache_control = cache_control_json cache_control } ];
      }
  | Developer_msg { content } -> developer_msg_json_to_json { role = "developer"; content }
  | User_msg_single_text { text; cache_control = None } ->
    user_msg_string_json_to_json { role = "user"; content = text }
  | User_msg_single_text { text; cache_control = Some cc } ->
    user_msg_parts_json_to_json
      { role = "user"; content = [ content_part_to_json (Or_text { text; cache_control = Some cc }) ] }
  | User_msg_parts { parts } ->
    user_msg_parts_json_to_json { role = "user"; content = List.map content_part_to_json parts }
  | Assistant_msg { content; tool_calls; cache_control } ->
    let cc_json = cache_control_json cache_control in
    (match tool_calls with
    | [] -> assistant_msg_text_json_to_json { role = "assistant"; content; cache_control = cc_json }
    | calls ->
      assistant_msg_with_tools_json_to_json
        {
          role = "assistant";
          content;
          tool_calls = List.map domain_tool_call_to_json_record calls;
          cache_control = cc_json;
        })
  | Tool_msg { tool_call_id; tool_name; content; cache_control } ->
    tool_msg_json_to_json
      { role = "tool"; tool_call_id; content; name = tool_name; cache_control = cache_control_json cache_control }
