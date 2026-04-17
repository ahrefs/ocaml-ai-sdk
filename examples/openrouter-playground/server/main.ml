(** OpenRouter Playground server.

    Single chat endpoint that reads OpenRouter-specific config from
    the X-OpenRouter-Config header. Demonstrates all 6 unique
    OpenRouter capabilities.

    Usage:
      dune exec examples/openrouter-playground/server/main.exe

    Set OPENROUTER_API_KEY environment variable. *)

open Melange_json.Primitives

(* --- Config types for JSON deserialization --- *)

type parsed_web_search = {
  enabled : bool; [@json.default false]
  max_results : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type parsed_provider_routing = {
  order : string list; [@json.default []]
  allow_fallbacks : bool option; [@json.default None]
  sort : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type parsed_reasoning = {
  effort : string option; [@json.default None]
  max_tokens : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type parsed_config = {
  model : string; [@json.default "openai/gpt-4o-mini"]
  fallback_models : string list; [@json.default []]
  web_search : parsed_web_search option; [@json.default None]
  provider_routing : parsed_provider_routing option; [@json.default None]
  usage : bool; [@json.default false]
  reasoning : parsed_reasoning option; [@json.default None]
  extra_body : Melange_json.t option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

(* --- Config parsing --- *)

let default_config =
  {
    model = "openai/gpt-4o-mini";
    fallback_models = [];
    web_search = None;
    provider_routing = None;
    usage = false;
    reasoning = None;
    extra_body = None;
  }

let parse_config req =
  match Cohttp.Header.get (Cohttp.Request.headers req) "x-openrouter-config" with
  | None -> default_config
  | Some json_str -> try parsed_config_of_json (Yojson.Basic.from_string json_str) with _ -> default_config

(* --- Build provider options --- *)

let reasoning_effort_of_string = function
  | "xhigh" -> Some Ai_provider_openrouter.Openrouter_options.Xhigh
  | "high" -> Some Ai_provider_openrouter.Openrouter_options.High
  | "medium" -> Some Ai_provider_openrouter.Openrouter_options.Medium
  | "low" -> Some Ai_provider_openrouter.Openrouter_options.Low
  | "minimal" -> Some Ai_provider_openrouter.Openrouter_options.Minimal
  | "none" -> Some Ai_provider_openrouter.Openrouter_options.None_
  | _ -> None

let build_provider_routing (p : parsed_provider_routing) : Ai_provider_openrouter.Openrouter_options.provider_prefs =
  {
    order = p.order;
    allow_fallbacks = p.allow_fallbacks;
    require_parameters = None;
    data_collection = None;
    only = [];
    ignore_ = [];
    quantizations = [];
    sort = p.sort;
    max_price = None;
    zdr = None;
    preferred_min_throughput = None;
    preferred_max_latency = None;
    enforce_distillable_text = None;
  }

let build_reasoning_budget (r : parsed_reasoning) =
  let open Ai_provider_openrouter.Openrouter_options in
  match r.max_tokens, r.effort with
  | Some n, _ -> Max_tokens n
  | None, Some e ->
    (match reasoning_effort_of_string e with
    | Some effort -> Effort effort
    | None -> No_budget)
  | None, None -> No_budget

let build_extra_body = function
  | Some (`Assoc fields) -> List.map (fun (k, v) -> k, (v : Melange_json.t :> Yojson.Basic.t)) fields
  | Some _ | None -> []

let build_provider_options (config : parsed_config) =
  let open Ai_provider_openrouter.Openrouter_options in
  let plugins =
    match config.web_search with
    | Some { enabled = true; max_results } ->
      [
        Web_search
          (Some { max_results; search_prompt = None; engine = None; include_domains = []; exclude_domains = [] });
      ]
    | Some { enabled = false; _ } | None -> []
  in
  let provider = Option.map build_provider_routing config.provider_routing in
  let usage =
    match config.usage with
    | true -> Some { include_ = true }
    | false -> None
  in
  let reasoning =
    Option.map
      (fun (r : parsed_reasoning) -> { enabled = Some true; exclude = None; budget = build_reasoning_budget r })
      config.reasoning
  in
  let include_reasoning =
    match config.reasoning with
    | Some _ -> Some true
    | None -> None
  in
  let extra_body = build_extra_body config.extra_body in
  let models =
    match config.fallback_models with
    | [] -> []
    | ms -> config.model :: ms
  in
  let opts = { default with models; plugins; provider; usage; reasoning; include_reasoning; extra_body } in
  to_provider_options opts

(* --- System prompt --- *)

let system_prompt = "You are a helpful assistant running on OpenRouter. Be concise and clear."

(* --- Static file serving --- *)

let static_dir =
  let exe_dir = Filename.dirname Sys.executable_name in
  let candidates = [ Filename.concat exe_dir "../"; "examples/openrouter-playground/"; "." ] in
  match List.find_opt (fun d -> Sys.file_exists (Filename.concat d "index.html")) candidates with
  | Some d -> d
  | None -> "examples/openrouter-playground/"

let content_type_of path =
  match Filename.extension path with
  | ".html" -> "text/html"
  | ".js" -> "application/javascript"
  | ".css" -> "text/css"
  | ".json" -> "application/json"
  | _ -> "application/octet-stream"

let serve_static path =
  let file_path = Filename.concat static_dir path in
  match Sys.file_exists file_path with
  | true ->
    let%lwt body = Lwt_io.with_file ~mode:Input file_path Lwt_io.read in
    let headers = Cohttp.Header.of_list [ "content-type", content_type_of path ] in
    Lwt.return (Cohttp.Response.make ~status:`OK ~headers (), Cohttp_lwt.Body.of_string body)
  | false ->
    let index_path = Filename.concat static_dir "index.html" in
    (match Sys.file_exists index_path with
    | true ->
      let%lwt body = Lwt_io.with_file ~mode:Input index_path Lwt_io.read in
      let headers = Cohttp.Header.of_list [ "content-type", "text/html" ] in
      Lwt.return (Cohttp.Response.make ~status:`OK ~headers (), Cohttp_lwt.Body.of_string body)
    | false ->
      let headers = Cohttp.Header.of_list [ "content-type", "text/plain" ] in
      Lwt.return (Cohttp.Response.make ~status:`Not_found ~headers (), Cohttp_lwt.Body.of_string "Not found"))

(* --- HTTP router --- *)

let meth_to_string = function
  | `GET -> "GET"
  | `POST -> "POST"
  | `OPTIONS -> "OPTIONS"
  | _ -> "OTHER"

let handler conn req body =
  let uri = Cohttp.Request.uri req in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth req in
  Printf.printf "[%s] %s\n%!" (meth_to_string meth) path;
  match meth, path with
  | `OPTIONS, "/api/chat" -> Ai_core.Server_handler.handle_cors_preflight conn req body
  | `POST, "/api/chat" ->
    let config = parse_config req in
    let model = Ai_provider_openrouter.language_model ~model:config.model () in
    let provider_options = build_provider_options config in
    Ai_core.Server_handler.handle_chat ~model ~system:system_prompt ~provider_options ~send_reasoning:true conn req body
  | `GET, "/" -> serve_static "index.html"
  | `GET, p when String.length p > 1 -> serve_static (String.sub p 1 (String.length p - 1))
  | _ ->
    let headers = Cohttp.Header.of_list [ "content-type", "text/plain" ] in
    Lwt.return (Cohttp.Response.make ~status:`Not_found ~headers (), Cohttp_lwt.Body.of_string "Not found")

let () =
  let port = 28602 in
  Printf.printf "OpenRouter Playground on http://localhost:%d\n%!" port;
  Printf.printf "Set OPENROUTER_API_KEY environment variable.\n%!";
  Printf.printf "Endpoint: POST /api/chat (config via X-OpenRouter-Config header)\n%!";
  let server =
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) (Cohttp_lwt_unix.Server.make ~callback:handler ())
  in
  Lwt_main.run server
