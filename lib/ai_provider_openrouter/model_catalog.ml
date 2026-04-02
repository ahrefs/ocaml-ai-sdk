type system_message_mode = Ai_provider_openai.Model_catalog.system_message_mode =
  | System
  | Developer
  | Remove

type model_capabilities = {
  is_reasoning_model : bool;
  system_message_mode : system_message_mode;
  default_max_tokens : int;
  supports_structured_output : bool;
  supports_vision : bool;
  supports_tool_calling : bool;
}

let standard_capabilities =
  {
    is_reasoning_model = false;
    system_message_mode = System;
    default_max_tokens = 4096;
    supports_structured_output = true;
    supports_vision = true;
    supports_tool_calling = true;
  }

let reasoning_capabilities =
  {
    is_reasoning_model = true;
    system_message_mode = Developer;
    default_max_tokens = 100_000;
    supports_structured_output = true;
    supports_vision = true;
    supports_tool_calling = true;
  }

(** Check if the model part (after provider/) indicates a reasoning model. *)
let is_reasoning_prefix model_part =
  String.starts_with ~prefix:"o1" model_part
  || String.starts_with ~prefix:"o3" model_part
  || String.starts_with ~prefix:"o4" model_part

let capabilities model_id =
  (* OpenRouter model IDs are "provider/model-name", e.g. "openai/o3-mini" *)
  match String.split_on_char '/' model_id with
  | [ _provider; model_part ] when is_reasoning_prefix model_part -> reasoning_capabilities
  | _ -> standard_capabilities

let is_reasoning_model model_id = (capabilities model_id).is_reasoning_model
