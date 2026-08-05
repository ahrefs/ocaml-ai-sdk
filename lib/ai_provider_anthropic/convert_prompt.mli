(** Convert SDK prompts to Anthropic Messages API format. *)

(** Anthropic message content types. *)

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
      cache_control : Cache_control.t option;
    }
  | A_thinking of {
      thinking : string;
      signature : string;
    }
  | A_redacted_thinking of { data : string }

type anthropic_message = {
  role : [ `User | `Assistant ];
  content : anthropic_content list;
}

(** Extract system messages with their per-message provider_options and return
    remaining messages. The order matches the input. *)
val extract_system :
  Ai_provider.Prompt.message list -> (string * Ai_provider.Provider_options.t) list * Ai_provider.Prompt.message list

(** Build the wire JSON for the [system] field on the Anthropic request.
    Returns [None] when no system messages are present. Always emits the
    array-of-blocks form (one text block per system message), matching
    upstream [@ai-sdk/anthropic]'s [convertToAnthropicPrompt]. *)
val system_to_json :
  ?validator:Cache_control_validator.t -> (string * Ai_provider.Provider_options.t) list -> Yojson.Basic.t option

(** Convert SDK messages to Anthropic format with message grouping
    for alternating user/assistant roles. Pass [~validator] to share the
    4-breakpoint budget with [system_to_json] and the tools conversion. *)
val convert_messages : ?validator:Cache_control_validator.t -> Ai_provider.Prompt.message list -> anthropic_message list

(** Serialize a content block to JSON. *)
val anthropic_content_to_json : anthropic_content -> Yojson.Basic.t

(** Serialize a message to JSON. *)
val anthropic_message_to_json : anthropic_message -> Yojson.Basic.t
