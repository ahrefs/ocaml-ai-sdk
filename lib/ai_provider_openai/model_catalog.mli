(** OpenAI model catalog and capability detection. *)

type system_message_mode =
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

type known_model =
  | Gpt_4_1
  | Gpt_4_1_mini
  | Gpt_4_1_nano
  | Gpt_4o
  | Gpt_4o_mini
  | Gpt_4_turbo
  | Gpt_4
  | Gpt_3_5_turbo
  | O1
  | O1_mini
  | O3
  | O3_mini
  | O4_mini
  | Custom of string

val to_model_id : known_model -> string

(** Exact match on base model IDs. Dated variants (e.g. "gpt-4o-2024-08-06")
    return [Custom]. Use [capabilities] for prefix-based detection. *)
val of_model_id : string -> known_model

(** Get capabilities from a raw model ID string.
    Routes through [of_model_id] first, with prefix-based fallback for [Custom] variants. *)
val capabilities : string -> model_capabilities

(** Convenience: check if a model ID is a reasoning model. *)
val is_reasoning_model : string -> bool
