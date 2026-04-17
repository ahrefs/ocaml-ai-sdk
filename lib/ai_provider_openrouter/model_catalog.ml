type system_message_mode = Ai_provider_openai.Model_catalog.system_message_mode =
  | System
  | Developer
  | Remove

(** Infer system_message_mode from model ID.
    [:thinking] suffix -> Developer, everything else -> System.
    Users can override via {!Openrouter_options.system_message_mode}. *)
let infer_system_message_mode model_id =
  match String.ends_with ~suffix:":thinking" model_id with
  | true -> Developer
  | false -> System
