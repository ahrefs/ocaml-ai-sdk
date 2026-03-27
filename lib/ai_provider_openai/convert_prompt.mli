(** Convert SDK prompt messages to OpenAI Chat Completions format. *)

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

(** Convert SDK messages to OpenAI format.
    Returns converted messages and any warnings generated. *)
val convert_messages :
  system_message_mode:Model_catalog.system_message_mode ->
  Ai_provider.Prompt.message list ->
  openai_message list * Ai_provider.Warning.t list

(** Serialize an OpenAI message to JSON. *)
val openai_message_to_json : openai_message -> Yojson.Basic.t
