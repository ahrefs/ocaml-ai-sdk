(** OpenRouter-specific provider options. *)

type reasoning_effort =
  | Low
  | Medium
  | High

type plugin =
  | Auto_router
  | Web_search of web_search_config option
  | File_parser

and web_search_config = { max_results : int option }

type route_preference =
  | Fastest
  | Cheapest

type provider_prefs = {
  allow_fallbacks : bool option;
  require_parameters : bool option;
  order : string list;
}

type t = {
  plugins : plugin list;
  transforms : string list;
  route : route_preference option;
  provider_preferences : provider_prefs option;
  api_keys : (string * string) list;
  include_reasoning : bool;
  reasoning_effort : reasoning_effort option;
  max_completion_tokens : int option;
  strict_json_schema : bool;
  system_message_mode : Model_catalog.system_message_mode option;
}

val default : t

type _ Ai_provider.Provider_options.key += Openrouter : t Ai_provider.Provider_options.key

val to_provider_options : t -> Ai_provider.Provider_options.t
val of_provider_options : Ai_provider.Provider_options.t -> t option

val reasoning_effort_to_string : reasoning_effort -> string
val plugins_to_json : plugin list -> Melange_json.t list
val route_preference_to_string : route_preference -> string
val provider_prefs_to_json : provider_prefs -> Melange_json.t
val api_keys_to_json : (string * string) list -> Melange_json.t
