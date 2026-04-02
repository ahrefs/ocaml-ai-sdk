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

let default =
  {
    plugins = [];
    transforms = [];
    route = None;
    provider_preferences = None;
    api_keys = [];
    include_reasoning = false;
    reasoning_effort = None;
    max_completion_tokens = None;
    strict_json_schema = true;
    system_message_mode = None;
  }

type _ Ai_provider.Provider_options.key += Openrouter : t Ai_provider.Provider_options.key

let to_provider_options opts = Ai_provider.Provider_options.set Openrouter opts Ai_provider.Provider_options.empty

let of_provider_options opts = Ai_provider.Provider_options.find Openrouter opts

let reasoning_effort_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"

let plugin_to_json = function
  | Auto_router -> `Assoc [ "id", `String "auto-router" ]
  | Web_search None -> `Assoc [ "id", `String "web" ]
  | Web_search (Some { max_results }) ->
    let base = [ "id", `String "web" ] in
    let extra =
      match max_results with
      | Some n -> [ "max_results", `Int n ]
      | None -> []
    in
    `Assoc (base @ extra)
  | File_parser -> `Assoc [ "id", `String "file-parser" ]

let plugins_to_json plugins = List.map plugin_to_json plugins

let route_preference_to_string = function
  | Fastest -> "fastest"
  | Cheapest -> "cheapest"

let provider_prefs_to_json (prefs : provider_prefs) =
  let fields =
    List.filter_map Fun.id
      [
        Option.map (fun v -> "allow_fallbacks", `Bool v) prefs.allow_fallbacks;
        Option.map (fun v -> "require_parameters", `Bool v) prefs.require_parameters;
        (match prefs.order with
        | [] -> None
        | order -> Some ("order", `List (List.map (fun s -> `String s) order)));
      ]
  in
  `Assoc fields

let api_keys_to_json keys = `Assoc (List.map (fun (provider, key) -> provider, `String key) keys)
