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
  supports_non_reasoning_parameters : bool;
}

type known_model =
  | Gpt_6_1_sol
  | Gpt_6_1_terra
  | Gpt_6_astra
  | Gpt_6_luna
  | Gpt_6_sol
  | Gpt_5_6
  | Gpt_5_6_luna
  | Gpt_5_6_sol
  | Gpt_5_6_terra
  | Gpt_5_5
  | Gpt_5_4
  | Gpt_5_4_mini
  | Gpt_5_4_nano
  | Gpt_5_2
  | Gpt_5_1
  | Gpt_5_1_chat_latest
  | Gpt_5
  | Gpt_5_mini
  | Gpt_5_nano
  | Gpt_5_chat_latest
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

(** Get capabilities from a raw model ID string. o-series models ("o1",
    "o3-mini", ...) and GPT-5 or later ("gpt-5", "gpt-5.4-mini", "gpt-6-sol",
    ...) are reasoning models, as in upstream's [@ai-sdk/openai], except a GPT
    chat variant without a minor version ("gpt-5-chat-latest"). Any other ID
    outside the catalog, dated ones included, matches by prefix: "gpt-4.1..."
    gets 32_768 default max tokens, "gpt-4o..." 16_384, and the rest the
    standard defaults. A dated variant can therefore differ from its base model
    ("gpt-4.1-nano-2025-04-14", "gpt-4-0613").
    [supports_non_reasoning_parameters] holds for GPT-5.1 and later GPT-5
    models, which accept [temperature], [top_p] and [logprobs] when the
    reasoning effort is [Re_none]. *)
val capabilities : string -> model_capabilities

(** Convenience: check if a model ID is a reasoning model. *)
val is_reasoning_model : string -> bool
