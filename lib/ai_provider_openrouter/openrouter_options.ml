open Melange_json.Primitives

(** Reasoning effort levels matching upstream OpenRouter API. *)
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
  (* Model settings *)
  models : string list;
  logit_bias : (int * float) list;
  logprobs : [ `Bool of bool | `Int of int ] option;
  parallel_tool_calls : bool option;
  user : string option;
  (* Reasoning *)
  reasoning : reasoning_config option;
  include_reasoning : bool option;
  (* Plugins & search *)
  plugins : plugin list;
  web_search_options : web_search_options option;
  (* Routing *)
  provider : provider_prefs option;
  (* Caching *)
  cache_control : cache_control option;
  (* Debug *)
  debug : debug_config option;
  (* Usage accounting *)
  usage : usage_config option;
  (* Extra body passthrough -- merged into request JSON *)
  extra_body : (string * Yojson.Basic.t) list;
  (* Local-only settings (not sent in request body) *)
  strict_json_schema : bool;
  system_message_mode : Model_catalog.system_message_mode option;
}

let default =
  {
    models = [];
    logit_bias = [];
    logprobs = None;
    parallel_tool_calls = None;
    user = None;
    reasoning = None;
    include_reasoning = None;
    plugins = [];
    web_search_options = None;
    provider = None;
    cache_control = None;
    debug = None;
    usage = None;
    extra_body = [];
    strict_json_schema = true;
    system_message_mode = None;
  }

type _ Ai_provider.Provider_options.key += Openrouter : t Ai_provider.Provider_options.key

let to_provider_options opts = Ai_provider.Provider_options.set Openrouter opts Ai_provider.Provider_options.empty
let of_provider_options opts = Ai_provider.Provider_options.find Openrouter opts

(* --- JSON serialization --- *)

let reasoning_effort_to_string = function
  | Xhigh -> "xhigh"
  | High -> "high"
  | Medium -> "medium"
  | Low -> "low"
  | Minimal -> "minimal"
  | None_ -> "none"

let reasoning_config_to_json (rc : reasoning_config) =
  let fields = [] in
  let fields =
    match rc.enabled with
    | Some b -> ("enabled", `Bool b) :: fields
    | None -> fields
  in
  let fields =
    match rc.exclude with
    | Some b -> ("exclude", `Bool b) :: fields
    | None -> fields
  in
  let fields =
    match rc.budget with
    | Max_tokens n -> ("max_tokens", `Int n) :: fields
    | Effort e -> ("effort", `String (reasoning_effort_to_string e)) :: fields
    | No_budget -> fields
  in
  `Assoc (List.rev fields)

let cache_control_to_json (cc : cache_control) =
  let fields = [ "type", `String cc.type_ ] in
  let fields =
    match cc.ttl with
    | Some ttl -> fields @ [ "ttl", `String ttl ]
    | None -> fields
  in
  `Assoc fields

let debug_config_to_json (dc : debug_config) =
  match dc.echo_upstream_body with
  | Some b -> `Assoc [ "echo_upstream_body", `Bool b ]
  | None -> `Assoc []

let web_search_options_to_json (wso : web_search_options) =
  let fields = [] in
  let fields =
    match wso.max_results with
    | Some n -> ("max_results", `Int n) :: fields
    | None -> fields
  in
  let fields =
    match wso.search_prompt with
    | Some s -> ("search_prompt", `String s) :: fields
    | None -> fields
  in
  let fields =
    match wso.engine with
    | Some e -> ("engine", `String e) :: fields
    | None -> fields
  in
  let fields =
    match wso.search_context_size with
    | Some s -> ("search_context_size", `String s) :: fields
    | None -> fields
  in
  `Assoc (List.rev fields)

let usage_config_to_json (uc : usage_config) = `Assoc [ "include", `Bool uc.include_ ]

let max_price_to_json (mp : max_price) =
  let add_opt name value fields =
    match value with
    | Some v -> (name, `Float v) :: fields
    | None -> fields
  in
  let fields =
    []
    |> add_opt "prompt" mp.prompt
    |> add_opt "completion" mp.completion
    |> add_opt "image" mp.image
    |> add_opt "audio" mp.audio
    |> add_opt "request" mp.request
  in
  `Assoc (List.rev fields)

let provider_prefs_to_json (pp : provider_prefs) =
  let fields = [] in
  let fields =
    match pp.order with
    | [] -> fields
    | order -> ("order", `List (List.map (fun s -> `String s) order)) :: fields
  in
  let fields =
    match pp.allow_fallbacks with
    | Some b -> ("allow_fallbacks", `Bool b) :: fields
    | None -> fields
  in
  let fields =
    match pp.require_parameters with
    | Some b -> ("require_parameters", `Bool b) :: fields
    | None -> fields
  in
  let fields =
    match pp.data_collection with
    | Some s -> ("data_collection", `String s) :: fields
    | None -> fields
  in
  let fields =
    match pp.only with
    | [] -> fields
    | only -> ("only", `List (List.map (fun s -> `String s) only)) :: fields
  in
  let fields =
    match pp.ignore_ with
    | [] -> fields
    | ignore_ -> ("ignore", `List (List.map (fun s -> `String s) ignore_)) :: fields
  in
  let fields =
    match pp.quantizations with
    | [] -> fields
    | qs -> ("quantizations", `List (List.map (fun s -> `String s) qs)) :: fields
  in
  let fields =
    match pp.sort with
    | Some s -> ("sort", `String s) :: fields
    | None -> fields
  in
  let fields =
    match pp.max_price with
    | Some mp -> ("max_price", max_price_to_json mp) :: fields
    | None -> fields
  in
  let fields =
    match pp.zdr with
    | Some b -> ("zdr", `Bool b) :: fields
    | None -> fields
  in
  let fields =
    match pp.preferred_min_throughput with
    | Some (Throughput_value v) -> ("preferred_min_throughput", `Float v) :: fields
    | Some (Throughput_percentile { percentile; min_provider_count }) ->
      let pf = [ "percentile", `Float percentile ] in
      let pf =
        match min_provider_count with
        | Some n -> pf @ [ "min_provider_count", `Int n ]
        | None -> pf
      in
      ("preferred_min_throughput", `Assoc pf) :: fields
    | None -> fields
  in
  let fields =
    match pp.preferred_max_latency with
    | Some (Latency_value v) -> ("preferred_max_latency", `Float v) :: fields
    | Some (Latency_percentile { percentile; max_provider_count }) ->
      let pf = [ "percentile", `Float percentile ] in
      let pf =
        match max_provider_count with
        | Some n -> pf @ [ "max_provider_count", `Int n ]
        | None -> pf
      in
      ("preferred_max_latency", `Assoc pf) :: fields
    | None -> fields
  in
  let fields =
    match pp.enforce_distillable_text with
    | Some b -> ("enforce_distillable_text", `Bool b) :: fields
    | None -> fields
  in
  `Assoc (List.rev fields)

let plugin_to_json = function
  | Web_search None -> `Assoc [ "id", `String "web" ]
  | Web_search (Some config) ->
    let fields = [ "id", `String "web" ] in
    let fields =
      match config.max_results with
      | Some n -> fields @ [ "max_results", `Int n ]
      | None -> fields
    in
    let fields =
      match config.search_prompt with
      | Some s -> fields @ [ "search_prompt", `String s ]
      | None -> fields
    in
    let fields =
      match config.engine with
      | Some e -> fields @ [ "engine", `String e ]
      | None -> fields
    in
    let fields =
      match config.include_domains with
      | [] -> fields
      | ds -> fields @ [ "include_domains", `List (List.map (fun s -> `String s) ds) ]
    in
    let fields =
      match config.exclude_domains with
      | [] -> fields
      | ds -> fields @ [ "exclude_domains", `List (List.map (fun s -> `String s) ds) ]
    in
    `Assoc fields
  | File_parser None -> `Assoc [ "id", `String "file-parser" ]
  | File_parser (Some config) ->
    let fields = [ "id", `String "file-parser" ] in
    let fields =
      match config.max_files with
      | Some n -> fields @ [ "max_files", `Int n ]
      | None -> fields
    in
    let fields =
      match config.pdf_engine with
      | Some e -> fields @ [ "pdf", `Assoc [ "engine", `String e ] ]
      | None -> fields
    in
    `Assoc fields
  | Auto_router None -> `Assoc [ "id", `String "auto-router" ]
  | Auto_router (Some config) ->
    let fields = [ "id", `String "auto-router" ] in
    let fields =
      match config.allowed_models with
      | [] -> fields
      | models -> fields @ [ "allowed_models", `List (List.map (fun s -> `String s) models) ]
    in
    `Assoc fields
  | Moderation -> `Assoc [ "id", `String "moderation" ]
  | Response_healing -> `Assoc [ "id", `String "response-healing" ]

let plugins_to_json plugins = List.map plugin_to_json plugins

let logit_bias_to_json bias = `Assoc (List.map (fun (token_id, value) -> string_of_int token_id, `Float value) bias)

(** Returns [(logprobs_json, top_logprobs_json option)].
    [`Bool b] -> [(`Bool b, None)];
    [`Int n] -> [(`Bool true, Some (`Int n))]. *)
let logprobs_to_json = function
  | `Bool b -> `Bool b, None
  | `Int n -> `Bool true, Some (`Int n)
