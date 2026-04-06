(** End-to-end example server for the Melange demo app.

    Serves multiple chat endpoints demonstrating different SDK features,
    plus static files for the frontend.

    Usage:
      dune exec examples/ai-e2e/server/main.exe

    Set ANTHROPIC_API_KEY and/or OPENAI_API_KEY environment variables. *)

open Melange_json.Primitives

(* --- Provider selection --- *)

let model_of_provider provider =
  match provider with
  | "openai" -> Ai_provider_openai.model "gpt-4o-mini"
  | "anthropic" -> Ai_provider_anthropic.model "claude-haiku-4-5-20251001"
  | unknown -> failwith (Printf.sprintf "Unknown provider: %s (expected 'anthropic' or 'openai')" unknown)

let provider_of_request req =
  match Cohttp.Header.get (Cohttp.Request.headers req) "x-provider" with
  | Some p -> p
  | None -> "anthropic"

(* --- Tools (same pattern as chat_server) --- *)

let json_of_schema schema = Yojson.Safe.to_basic (Ppx_deriving_jsonschema_runtime.json_schema schema)

type city_args = { city : string } [@@deriving jsonschema, of_json]

type weather_result = {
  city : string;
  temperature : int;
  condition : string;
  unit_ : string; [@json.key "unit"]
}
[@@deriving to_json]

let get_weather : Ai_core.Core_tool.t =
  Ai_core.Core_tool.create ~description:"Get the current weather for a city. Returns temperature and conditions."
    ~parameters:(json_of_schema city_args_jsonschema)
    ~execute:(fun args ->
      let city = try (city_args_of_json args).city with _ -> "unknown" in
      let temperature, condition =
        match String.lowercase_ascii city with
        | "paris" -> 18, "partly cloudy"
        | "london" -> 12, "rainy"
        | "tokyo" -> 26, "sunny"
        | "new york" -> 15, "windy"
        | _ -> 20, "clear"
      in
      Lwt.return (weather_result_to_json { city; temperature; condition; unit_ = "celsius" }))
    ()

type search_args = {
  query : string;
  num_results : int;
}
[@@deriving jsonschema, of_json]

type search_result_item = {
  title : string;
  url : string;
  snippet : string;
}
[@@deriving to_json]

type search_results = { results : search_result_item list } [@@deriving to_json]

let search_web : Ai_core.Core_tool.t =
  Ai_core.Core_tool.create ~description:"Search the web for information. Returns a list of relevant results."
    ~parameters:(json_of_schema search_args_jsonschema)
    ~execute:(fun args ->
      let { query; num_results } = try search_args_of_json args with _ -> { query = "unknown"; num_results = 3 } in
      let results =
        List.init (min num_results 3) (fun i ->
          {
            title = Printf.sprintf "Result %d for: %s" (i + 1) query;
            url = Printf.sprintf "https://example.com/search?q=%s&p=%d" (String.lowercase_ascii query) (i + 1);
            snippet = Printf.sprintf "Simulated search result about '%s'." query;
          })
      in
      Lwt.return (search_results_to_json { results }))
    ()

let tools = [ "get_weather", get_weather; "search_web", search_web ]

(* --- Approval tools (weather needs approval, search doesn't) --- *)

let approval_weather : Ai_core.Core_tool.t =
  Ai_core.Core_tool.create_with_approval
    ~description:"Get the current weather for a city. Requires user approval before execution."
    ~parameters:(json_of_schema city_args_jsonschema)
    ~execute:(fun args ->
      let city = try (city_args_of_json args).city with _ -> "unknown" in
      let temperature, condition =
        match String.lowercase_ascii city with
        | "paris" -> 18, "partly cloudy"
        | "london" -> 12, "rainy"
        | "tokyo" -> 26, "sunny"
        | "new york" -> 15, "windy"
        | _ -> 20, "clear"
      in
      Lwt.return (weather_result_to_json { city; temperature; condition; unit_ = "celsius" }))
    ()

let approval_tools = [ "get_weather", approval_weather; "search_web", search_web ]

(* --- Client-side tools (server defines, client provides results) --- *)

let get_location : Ai_core.Core_tool.t =
  Ai_core.Core_tool.create_client_tool ~description:"Get the user's current location. The browser provides this data."
    ~parameters:(`Assoc [ "type", `String "object"; "properties", `Assoc [] ])
    ()

let client_tools_list = [ "get_location", get_location; "get_weather", approval_weather ]

(* --- Structured output schema --- *)

type data_point = {
  label : string;
  value : string;
}
[@@deriving jsonschema]

type structured_response = {
  summary : string;
  data : data_point list;
}
[@@deriving jsonschema]

let output =
  Ai_core.Output.object_ ~name:"structured_response" ~schema:(json_of_schema structured_response_jsonschema) ()

(* --- System prompts --- *)

let basic_system = "You are a helpful assistant. Be concise and clear in your responses."

let tools_system =
  {|You are a helpful assistant with access to tools.
When asked about weather, use the get_weather tool.
When asked to search, use the search_web tool.
You can use multiple tools in sequence to build a complete answer.|}

let structured_system =
  {|You are a helpful assistant. Always respond with structured data.
Your response must be raw JSON (no markdown, no code fences) with:
- "summary": a concise natural language answer
- "data": an array of {"label": "...", "value": "..."} key data points|}

let reasoning_system = "You are a helpful assistant. Think through problems step by step before answering."

let approval_system =
  {|You are a helpful assistant with access to tools.
When asked about weather, use the get_weather tool. This tool requires user approval.
When asked to search, use the search_web tool. This tool executes immediately.
You can use multiple tools in sequence.|}

let client_tools_system =
  {|You are a helpful assistant. You can get the user's location and check the weather.
When asked about local weather or location-dependent queries, first use get_location, then use get_weather with the result.
When the user asks "what's the weather here?" or similar, use both tools.|}

(* --- Thinking / reasoning provider options --- *)

let anthropic_thinking_options =
  let budget = Ai_provider_anthropic.Thinking.budget_exn 4096 in
  let thinking : Ai_provider_anthropic.Thinking.t = { enabled = true; budget_tokens = budget } in
  let opts = { Ai_provider_anthropic.Anthropic_options.default with thinking = Some thinking } in
  Ai_provider_anthropic.Anthropic_options.to_provider_options opts

(* --- Completion handler (plain text stream for useCompletion) --- *)

type completion_request = { prompt : string } [@@deriving of_json]

let handle_completion ~model conn req body =
  ignore (conn : Cohttp_lwt_unix.Server.conn);
  ignore (req : Cohttp.Request.t);
  let%lwt body_str = Cohttp_lwt.Body.to_string body in
  let prompt = try (completion_request_of_json (Yojson.Basic.from_string body_str)).prompt with _ -> "" in
  let result = Ai_core.Stream_text.stream_text ~model ~system:basic_system ~prompt () in
  let body = Cohttp_lwt.Body.of_stream result.text_stream in
  let headers =
    Cohttp.Header.of_list
      ([ "content-type", "text/plain; charset=utf-8"; "cache-control", "no-cache" ]
      @ Ai_core.Server_handler.cors_headers)
  in
  Lwt.return (Cohttp.Response.make ~status:`OK ~headers (), body)

(* --- Static file serving --- *)

let static_dir =
  let exe_dir = Filename.dirname Sys.executable_name in
  (* When running via dune exec, the executable is in _build/.../server/
     but the static files are in examples/ai-e2e/ *)
  let candidates = [ Filename.concat exe_dir "../"; "examples/ai-e2e/"; "." ] in
  match List.find_opt (fun d -> Sys.file_exists (Filename.concat d "index.html")) candidates with
  | Some d -> d
  | None -> "examples/ai-e2e/"

let content_type_of path =
  match Filename.extension path with
  | ".html" -> "text/html"
  | ".js" -> "application/javascript"
  | ".css" -> "text/css"
  | ".json" -> "application/json"
  | ".png" -> "image/png"
  | ".svg" -> "image/svg+xml"
  | _ -> "application/octet-stream"

let serve_static path =
  let file_path = Filename.concat static_dir path in
  if Sys.file_exists file_path then begin
    let%lwt body = Lwt_io.with_file ~mode:Input file_path Lwt_io.read in
    let headers = Cohttp.Header.of_list [ "content-type", content_type_of path ] in
    Lwt.return (Cohttp.Response.make ~status:`OK ~headers (), Cohttp_lwt.Body.of_string body)
  end
  else begin
    (* SPA fallback: serve index.html for unknown paths *)
    let index_path = Filename.concat static_dir "index.html" in
    if Sys.file_exists index_path then begin
      let%lwt body = Lwt_io.with_file ~mode:Input index_path Lwt_io.read in
      let headers = Cohttp.Header.of_list [ "content-type", "text/html" ] in
      Lwt.return (Cohttp.Response.make ~status:`OK ~headers (), Cohttp_lwt.Body.of_string body)
    end
    else begin
      let headers = Cohttp.Header.of_list [ "content-type", "text/plain" ] in
      Lwt.return (Cohttp.Response.make ~status:`Not_found ~headers (), Cohttp_lwt.Body.of_string "Not found")
    end
  end

(* --- HTTP router --- *)

let handler conn req body =
  let uri = Cohttp.Request.uri req in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth req in
  Printf.printf "[%s] %s\n%!"
    (match meth with
    | `GET -> "GET"
    | `POST -> "POST"
    | `OPTIONS -> "OPTIONS"
    | _ -> "OTHER")
    path;
  let provider = provider_of_request req in
  let model = model_of_provider provider in
  match meth, path with
  (* CORS preflight *)
  | `OPTIONS, _ when String.length path >= 9 && String.sub path 0 9 = "/api/chat" ->
    Ai_core.Server_handler.handle_cors_preflight conn req body
  (* Chat endpoints *)
  | `POST, "/api/chat/basic" -> Ai_core.Server_handler.handle_chat ~model ~system:basic_system conn req body
  | `POST, "/api/chat/tools" ->
    Ai_core.Server_handler.handle_chat ~model ~system:tools_system ~tools ~max_steps:5 conn req body
  | `POST, "/api/chat/reasoning" ->
    Ai_core.Server_handler.handle_chat ~model ~system:reasoning_system ~send_reasoning:true
      ~provider_options:anthropic_thinking_options ~max_output_tokens:16384 conn req body
  | `POST, "/api/chat/structured" ->
    Ai_core.Server_handler.handle_chat ~model ~system:structured_system ~tools ~max_steps:5 ~output conn req body
  | `POST, "/api/chat/client-tools" ->
    (* Sonnet for this demo — Haiku struggles with multi-step tool chaining *)
    let client_tools_model = Ai_provider_anthropic.model "claude-sonnet-4-6" in
    Ai_core.Server_handler.handle_chat ~model:client_tools_model ~system:client_tools_system ~tools:client_tools_list
      ~max_steps:5 conn req body
  | `POST, "/api/chat/completion" -> handle_completion ~model conn req body
  | `POST, "/api/chat/approval" ->
    Ai_core.Server_handler.handle_chat ~model ~system:approval_system ~tools:approval_tools ~max_steps:5 conn req body
  | `POST, "/api/chat/web-search" -> Ai_core.Server_handler.handle_chat ~model ~system:basic_system conn req body
  (* Static files *)
  | `GET, "/" -> serve_static "index.html"
  | `GET, p when String.length p > 1 -> serve_static (String.sub p 1 (String.length p - 1))
  | _ ->
    let headers = Cohttp.Header.of_list [ "content-type", "text/plain" ] in
    Lwt.return (Cohttp.Response.make ~status:`Not_found ~headers (), Cohttp_lwt.Body.of_string "Not found")

let () =
  let port = 28601 in
  Printf.printf "AI SDK E2E examples on http://localhost:%d\n%!" port;
  Printf.printf "Static files: %s\n%!" static_dir;
  Printf.printf "Endpoints:\n%!";
  Printf.printf "  POST /api/chat/basic        — Basic streaming chat\n%!";
  Printf.printf "  POST /api/chat/tools        — Tool use (weather, search)\n%!";
  Printf.printf "  POST /api/chat/reasoning    — Extended thinking\n%!";
  Printf.printf "  POST /api/chat/structured   — Structured output\n%!";
  Printf.printf "  POST /api/chat/client-tools — Client-side tools\n%!";
  Printf.printf "  POST /api/chat/completion   — Text completion\n%!";
  Printf.printf "  POST /api/chat/approval     — Tool approval\n%!";
  Printf.printf "  POST /api/chat/web-search   — Web search (stub)\n%!";
  let server =
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) (Cohttp_lwt_unix.Server.make ~callback:handler ())
  in
  Lwt_main.run server
