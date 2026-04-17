(** OpenRouter-specific provider options.

    Matches the upstream TypeScript [@openrouter/ai-sdk-provider] OpenRouterChatSettings type. *)

type reasoning_effort =
  | Xhigh
  | High
  | Medium
  | Low
  | Minimal
  | None_

type reasoning_config = {
  enabled : bool option;
  exclude : bool option;
  budget : reasoning_budget;
}

and reasoning_budget =
  | Max_tokens of int
  | Effort of reasoning_effort
  | No_budget

type cache_control = {
  type_ : string;
  ttl : string option;
}

type debug_config = { echo_upstream_body : bool option }

type web_search_options = {
  max_results : int option;
  search_prompt : string option;
  engine : string option;
  search_context_size : string option;
}

type usage_config = { include_ : bool }

type max_price = {
  prompt : float option;
  completion : float option;
  image : float option;
  audio : float option;
  request : float option;
}

type throughput_percentile = {
  percentile : float;
  min_provider_count : int option;
}

type latency_percentile = {
  percentile : float;
  max_provider_count : int option;
}

type throughput_preference =
  | Throughput_value of float
  | Throughput_percentile of throughput_percentile

type latency_preference =
  | Latency_value of float
  | Latency_percentile of latency_percentile

type provider_prefs = {
  order : string list;
  allow_fallbacks : bool option;
  require_parameters : bool option;
  data_collection : string option;
  only : string list;
  ignore_ : string list;
  quantizations : string list;
  sort : string option;
  max_price : max_price option;
  zdr : bool option;
  preferred_min_throughput : throughput_preference option;
  preferred_max_latency : latency_preference option;
  enforce_distillable_text : bool option;
}

type plugin =
  | Web_search of web_search_plugin_config option
  | File_parser of file_parser_plugin_config option
  | Auto_router of auto_router_plugin_config option
  | Moderation
  | Response_healing

and web_search_plugin_config = {
  max_results : int option;
  search_prompt : string option;
  engine : string option;
  include_domains : string list;
  exclude_domains : string list;
}

and file_parser_plugin_config = {
  max_files : int option;
  pdf_engine : string option;
}

and auto_router_plugin_config = { allowed_models : string list }

type t = {
  models : string list;
  logit_bias : (int * float) list;
  logprobs : [ `Bool of bool | `Int of int ] option;
  parallel_tool_calls : bool option;
  user : string option;
  reasoning : reasoning_config option;
  include_reasoning : bool option;
  plugins : plugin list;
  web_search_options : web_search_options option;
  provider : provider_prefs option;
  cache_control : cache_control option;
  debug : debug_config option;
  usage : usage_config option;
  extra_body : (string * Yojson.Basic.t) list;
  strict_json_schema : bool;
  system_message_mode : Model_catalog.system_message_mode option;
}

val default : t

type _ Ai_provider.Provider_options.key += Openrouter : t Ai_provider.Provider_options.key

val to_provider_options : t -> Ai_provider.Provider_options.t
val of_provider_options : Ai_provider.Provider_options.t -> t option

(** JSON serialization functions. *)

val reasoning_effort_to_string : reasoning_effort -> string
val reasoning_config_to_json : reasoning_config -> Melange_json.t
val cache_control_to_json : cache_control -> Melange_json.t
val debug_config_to_json : debug_config -> Melange_json.t
val web_search_options_to_json : web_search_options -> Melange_json.t
val usage_config_to_json : usage_config -> Melange_json.t
val max_price_to_json : max_price -> Melange_json.t
val provider_prefs_to_json : provider_prefs -> Melange_json.t
val plugin_to_json : plugin -> Melange_json.t
val plugins_to_json : plugin list -> Melange_json.t list
val logit_bias_to_json : (int * float) list -> Melange_json.t
val logprobs_to_json : [ `Bool of bool | `Int of int ] -> Melange_json.t * Melange_json.t option
