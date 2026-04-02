(** Model capabilities for OpenRouter models.

    OpenRouter proxies 300+ models so there is no fixed catalog.
    Capabilities are inferred from model ID prefixes. *)

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

(** Infer capabilities from model ID using prefix heuristics.
    Models containing [/o1], [/o3], [/o4] are treated as reasoning models. *)
val capabilities : string -> model_capabilities

val is_reasoning_model : string -> bool
