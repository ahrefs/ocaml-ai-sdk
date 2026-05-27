(** Convert SDK prompt messages to OpenRouter Chat Completions format.

    Forked from {!Ai_provider_openai.Convert_prompt} to mirror upstream
    [@openrouter/ai-sdk-provider]'s
    [src/chat/convert-to-openrouter-chat-messages.ts]. The key differences
    from the OpenAI converter are:

    - {b System messages} are always wrapped in a single-element
      [text] content-part array, even without cache control
      (upstream wire format).
    - {b User} single-text messages switch from a plain [string]
      content to a one-element parts array iff a [cache_control] is
      resolved (message-level falls back to part-level).
    - {b User} multi-part messages propagate message-level
      [cache_control] to the {e last} text part only (per-part wins).
      No root-level [cache_control] on multi-part user messages.
    - {b Assistant} part-level cache markers are hoisted to the
      root-level [cache_control] field used by OpenRouter assistant
      messages.
    - {b Tool} messages include a [name] field and a root-level
      [cache_control] (message-level wins over per-result).

    Per-part / per-message cache control is read via
    {!Cache_control_options.get_cache_control}, which falls back to
    the Anthropic key for cross-provider prompt compatibility. *)

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

(** Convert SDK messages to OpenRouter wire-format messages.
    Returns converted messages and any warnings generated. *)
val convert_messages :
  system_message_mode:Model_catalog.system_message_mode ->
  Ai_provider.Prompt.message list ->
  openrouter_message list * Ai_provider.Warning.t list

(** Serialize an OpenRouter message to JSON. *)
val openrouter_message_to_json : openrouter_message -> Yojson.Basic.t
