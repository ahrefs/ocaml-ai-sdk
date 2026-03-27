(** OpenAI-specific provider options. *)

type reasoning_effort =
  | Re_none
  | Minimal
  | Low
  | Medium
  | High
  | Xhigh

type service_tier =
  | St_auto
  | Flex
  | Priority
  | St_default

type prediction = {
  type_ : string;
  content : string;
}

type t = {
  logit_bias : (int * float) list;
  logprobs : int option;
  parallel_tool_calls : bool option;
  user : string option;
  reasoning_effort : reasoning_effort option;
  max_completion_tokens : int option;
  store : bool option;
  metadata : (string * string) list;
  prediction : prediction option;
  service_tier : service_tier option;
  strict_json_schema : bool;
  system_message_mode : Model_catalog.system_message_mode option;
}

val default : t

type _ Ai_provider.Provider_options.key += Openai : t Ai_provider.Provider_options.key

val to_provider_options : t -> Ai_provider.Provider_options.t
val of_provider_options : Ai_provider.Provider_options.t -> t option

val reasoning_effort_to_string : reasoning_effort -> string
val service_tier_to_string : service_tier -> string
