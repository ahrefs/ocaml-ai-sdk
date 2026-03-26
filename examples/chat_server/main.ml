(** Multi-tool chat agent with structured output using the Core SDK.

    Demonstrates:
    - Multiple tools with JSON Schema derived from OCaml types (ppx_deriving_jsonschema)
    - Structured output (Output.object_) with schema derived from OCaml types
    - Tools + Output together: model calls tools, then responds with validated JSON
    - Multi-step tool execution (agent loop with max_steps:5)
    - UIMessage stream protocol v1 for useChat() interop

    Set ANTHROPIC_API_KEY environment variable before running.

    Usage:
      dune exec examples/chat_server/main.exe

    Test with curl:
      curl -N -X POST http://localhost:28601/chat \
        -H "Content-Type: application/json" \
        -d '{"messages":[{"role":"user","content":"What is the weather in Paris?"}]}' *)

open Melange_json.Primitives

let model = Ai_provider_anthropic.model "claude-sonnet-4-6"

(** Convert a ppx_deriving_jsonschema schema (Yojson.Safe.t) to Yojson.Basic.t
    for use as Core_tool.parameters. *)
let json_of_schema schema = Yojson.Safe.to_basic (Ppx_deriving_jsonschema_runtime.json_schema schema)

(* --- Tool: get_weather --- *)

type city_args = { city : string } [@@deriving jsonschema, of_json]

type weather_result = {
  city : string;
  temperature : int;
  condition : string;
  unit_ : string; [@json.key "unit"]
}
[@@deriving to_json]

let get_weather : Ai_core.Core_tool.t =
  {
    description = Some "Get the current weather for a city. Returns temperature and conditions.";
    parameters = json_of_schema city_args_jsonschema;
    execute =
      (fun args ->
        let city = try (city_args_of_json args).city with _ -> "unknown" in
        let temperature, condition =
          match String.lowercase_ascii city with
          | "paris" -> 18, "partly cloudy"
          | "london" -> 12, "rainy"
          | "tokyo" -> 26, "sunny"
          | "new york" -> 15, "windy"
          | _ -> 20, "clear"
        in
        Lwt.return (weather_result_to_json { city; temperature; condition; unit_ = "celsius" }));
  }

(* --- Tool: search_web --- *)

type search_args = {
  query : string;
  num_results : int option;
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
  {
    description = Some "Search the web for information. Returns a list of relevant results.";
    parameters = json_of_schema search_args_jsonschema;
    execute =
      (fun args ->
        let { query; num_results } =
          try search_args_of_json args with _ -> { query = "unknown"; num_results = None }
        in
        let n =
          match num_results with
          | Some n -> n
          | None -> 3
        in
        let results =
          List.init (min n 3) (fun i ->
            {
              title = Printf.sprintf "Result %d for: %s" (i + 1) query;
              url = Printf.sprintf "https://example.com/search?q=%s&p=%d" (String.lowercase_ascii query) (i + 1);
              snippet =
                Printf.sprintf
                  "This is a simulated search result about '%s'. In a real implementation, this would query a search \
                   API."
                  query;
            })
        in
        Lwt.return (search_results_to_json { results }));
  }

(* --- Tools list --- *)

let tools = [ "get_weather", get_weather; "search_web", search_web ]

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

let output = Ai_core.Output.object_ ~name:"structured_response" ~schema:(json_of_schema structured_response_jsonschema) ()

(* --- System prompt --- *)

let system_prompt =
  {|You are a helpful assistant with access to tools. Use them when needed to answer questions accurately.

When asked about weather, use the get_weather tool.
When asked about facts or topics you're not sure about, use the search_web tool.
You can use multiple tools in sequence to build a complete answer.

Your final response must be structured JSON with:
- "summary": a concise natural language answer
- "data": an array of {"label": "...", "value": "..."} key data points|}

(* --- HTTP handler --- *)

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
  match meth, path with
  | `OPTIONS, "/chat" -> Ai_core.Server_handler.handle_cors_preflight conn req body
  | _, "/chat" ->
    Lwt.catch
      (fun () ->
        Ai_core.Server_handler.handle_chat ~model ~system:system_prompt ~tools ~max_steps:5 ~output ~send_reasoning:true
          conn req body)
      (fun exn ->
        let msg = Printexc.to_string exn in
        Printf.eprintf "[ERROR] /chat: %s\n%!" msg;
        let body = Cohttp_lwt.Body.of_string msg in
        let headers = Cohttp.Header.of_list (("content-type", "text/plain") :: Ai_core.Server_handler.cors_headers) in
        let response = Cohttp.Response.make ~status:`Internal_server_error ~headers () in
        Lwt.return (response, body))
  | _ ->
    let body = Cohttp_lwt.Body.of_string "Not found" in
    let headers = Cohttp.Header.of_list [ "content-type", "text/plain" ] in
    let response = Cohttp.Response.make ~status:`Not_found ~headers () in
    Lwt.return (response, body)

let () =
  let port = 28601 in
  Printf.printf "Chat agent on http://localhost:%d/chat (max_steps: 5, tools: %d)\n%!" port (List.length tools);
  let server =
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) (Cohttp_lwt_unix.Server.make ~callback:handler ())
  in
  Lwt_main.run server
