(** Model catalog for inferring per-model capabilities (e.g. system message mode). *)

type system_message_mode = Ai_provider_openai.Model_catalog.system_message_mode =
  | System
  | Developer
  | Remove

val infer_system_message_mode : string -> system_message_mode
