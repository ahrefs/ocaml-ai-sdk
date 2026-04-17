# OpenRouter Playground Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a single-page playground example that showcases all 6 unique OpenRouter capabilities: model selection, web search plugin, provider routing, usage tracking, reasoning configuration, and extra body passthrough.

**Architecture:** A standalone example at `examples/openrouter-playground/` with a Melange client (single page with chat + settings panel) and an OCaml server. The client sends settings via per-request `X-OpenRouter-Config` JSON header using `send_message_with_options`. The server parses that header, builds `Openrouter_options.t`, creates the model, and calls `handle_chat` with `provider_options`. No new library code needed -- this is purely a consumer of the existing provider API.

**Tech Stack:** Server: OCaml, Lwt, Cohttp, ai_core, ai_provider_openrouter, melange-json-native. Client: Melange, reason-react, ai_sdk_react.

---

### Task 1: Server -- dune files and skeleton

**Files:**
- Create: `examples/openrouter-playground/server/dune`
- Create: `examples/openrouter-playground/server/main.ml`

**Step 1: Create server dune file**

```
(include_subdirs no)

(executable
 (name main)
 (libraries
  ai_provider
  ai_provider_openrouter
  ai_core
  lwt
  lwt.unix
  cohttp
  cohttp-lwt
  cohttp-lwt-unix
  yojson
  melange-json-native)
 (preprocess
  (pps lwt_ppx melange-json-native.ppx)))
```

**Step 2: Create minimal server with `/api/chat` endpoint**

The server should:
1. Read `X-OpenRouter-Config` header from request (JSON string)
2. Parse it into a config record
3. Build `Openrouter_options.t` from the config
4. Create an OpenRouter model with the configured model ID
5. Call `handle_chat` with the built `provider_options`
6. Serve static files for the client

**Config JSON shape (what the client sends):**

```json
{
  "model": "openai/gpt-4o-mini",
  "fallback_models": ["anthropic/claude-haiku-4-5-20251001"],
  "web_search": { "enabled": true, "max_results": 5 },
  "provider": { "order": ["openai"], "allow_fallbacks": true, "sort": "price" },
  "usage": true,
  "reasoning": { "effort": "high" },
  "extra_body": {}
}
```

All fields are optional with sensible defaults.

**Server main.ml structure:**

```ocaml
(** OpenRouter Playground server.

    Single chat endpoint that reads OpenRouter-specific config from
    the X-OpenRouter-Config header. Demonstrates all 6 unique
    OpenRouter capabilities.

    Usage:
      dune exec examples/openrouter-playground/server/main.exe

    Set OPENROUTER_API_KEY environment variable. *)

open Melange_json.Primitives

(* --- Config parsing --- *)

(** Parsed from X-OpenRouter-Config header JSON. All fields optional. *)
type playground_config = {
  model : string; [@json.default "openai/gpt-4o-mini"]
  fallback_models : string list; [@json.default []]
  web_search : web_search_config option; [@json.default None]
  provider : provider_config option; [@json.default None]
  usage : bool; [@json.default false]
  reasoning : reasoning_config option; [@json.default None]
  extra_body : Melange_json.t option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

and web_search_config = {
  enabled : bool; [@json.default false]
  max_results : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

and provider_config = {
  order : string list; [@json.default []]
  allow_fallbacks : bool option; [@json.default None]
  sort : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

and reasoning_config = {
  effort : string option; [@json.default None]
  max_tokens : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

let default_config =
  {
    model = "openai/gpt-4o-mini";
    fallback_models = [];
    web_search = None;
    provider = None;
    usage = false;
    reasoning = None;
    extra_body = None;
  }

let parse_config req =
  match Cohttp.Header.get (Cohttp.Request.headers req) "x-openrouter-config" with
  | None -> default_config
  | Some json_str ->
    (try playground_config_of_json (Yojson.Basic.from_string json_str)
     with _ -> default_config)

(* --- Build provider options from config --- *)

let reasoning_effort_of_string = function
  | "xhigh" -> Some Ai_provider_openrouter.Openrouter_options.Xhigh
  | "high" -> Some High
  | "medium" -> Some Medium
  | "low" -> Some Low
  | "minimal" -> Some Minimal
  | "none" -> Some None_
  | _ -> None

let build_provider_options (config : playground_config) =
  let open Ai_provider_openrouter.Openrouter_options in
  let plugins =
    match config.web_search with
    | Some { enabled = true; max_results } ->
      [ Web_search (Some { max_results; search_prompt = None; engine = None }) ]
    | Some { enabled = false; _ } | None -> []
  in
  let provider =
    Option.map
      (fun (p : provider_config) : provider_prefs ->
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
        })
      config.provider
  in
  let usage =
    match config.usage with
    | true -> Some { include_ = true }
    | false -> None
  in
  let reasoning =
    Option.map
      (fun (r : reasoning_config) : reasoning_config_ ->
        let budget =
          match r.max_tokens, r.effort with
          | Some n, _ -> Max_tokens n
          | None, Some e ->
            (match reasoning_effort_of_string e with
            | Some effort -> Effort effort
            | None -> No_budget)
          | None, None -> No_budget
        in
        { enabled = Some true; exclude = None; budget })
      config.reasoning
  in
  let include_reasoning =
    match config.reasoning with
    | Some _ -> Some true
    | None -> None
  in
  let extra_body =
    match config.extra_body with
    | Some (`Assoc fields) ->
      List.map (fun (k, v) -> k, (v : Melange_json.t :> Yojson.Basic.t)) fields
    | _ -> []
  in
  let models =
    match config.fallback_models with
    | [] -> []
    | ms -> config.model :: ms
  in
  let opts =
    { default with
      models;
      plugins;
      provider;
      usage;
      reasoning;
      include_reasoning;
      extra_body;
    }
  in
  to_provider_options opts

(* --- System prompt --- *)

let system_prompt =
  "You are a helpful assistant running on OpenRouter. Be concise and clear."

(* --- Static file serving --- *)
(* Same pattern as ai-e2e server *)

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
  if Sys.file_exists file_path then begin
    let%lwt body = Lwt_io.with_file ~mode:Input file_path Lwt_io.read in
    let headers = Cohttp.Header.of_list [ "content-type", content_type_of path ] in
    Lwt.return (Cohttp.Response.make ~status:`OK ~headers (), Cohttp_lwt.Body.of_string body)
  end
  else begin
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
  match meth, path with
  | `OPTIONS, "/api/chat" -> Ai_core.Server_handler.handle_cors_preflight conn req body
  | `POST, "/api/chat" ->
    let config = parse_config req in
    let model = Ai_provider_openrouter.language_model ~model:config.model () in
    let provider_options = build_provider_options config in
    Ai_core.Server_handler.handle_chat ~model ~system:system_prompt ~provider_options
      ~send_reasoning:true conn req body
  | `GET, "/" -> serve_static "index.html"
  | `GET, p when String.length p > 1 ->
    serve_static (String.sub p 1 (String.length p - 1))
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
```

Note: `reasoning_config_` is used to avoid shadowing the JSON-parsed `reasoning_config` type. We may need to name these differently -- use `parsed_reasoning_config` for the JSON type and keep the provider type as-is.

**Step 3: Verify server builds**

Run: `dune build examples/openrouter-playground/server/main.exe 2>&1`
Expected: builds successfully

**Step 4: Commit**

```bash
git add examples/openrouter-playground/server/
git commit -m "feat: add OpenRouter playground server skeleton"
```

---

### Task 2: Client -- dune files, index.html, build script

**Files:**
- Create: `examples/openrouter-playground/dune`
- Create: `examples/openrouter-playground/index.html`
- Create: `examples/openrouter-playground/build.js`
- Create: `examples/openrouter-playground/package.json`

**Step 1: Create client dune file**

Follow the ai-e2e pattern exactly:

```
(melange.emit
 (target output)
 (alias openrouter_playground)
 (libraries ai_sdk_react reason-react)
 (preprocess
  (pps melange.ppx reason-react-ppx))
 (module_systems es6))

(rule
 (alias bundle)
 (deps
  (alias openrouter_playground))
 (action
  (bash
   "cd \"$(git rev-parse --show-toplevel)/examples/openrouter-playground\" && node build.js")))
```

**Step 2: Create index.html**

Minimal HTML shell like ai-e2e:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpenRouter Playground</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  </style>
</head>
<body>
  <div id="root"></div>
  <script src="dist/main.js" type="module"></script>
</body>
</html>
```

**Step 3: Create build.js**

Same esbuild pattern as ai-e2e:

```javascript
const esbuild = require("esbuild");
esbuild.build({
  entryPoints: ["output/examples/openrouter-playground/main.js"],
  bundle: true,
  outdir: "dist",
  format: "esm",
  splitting: true,
  minify: false,
  sourcemap: true,
  external: [],
}).catch(() => process.exit(1));
```

**Step 4: Create package.json**

```json
{
  "name": "openrouter-playground",
  "private": true,
  "scripts": {
    "build": "dune build @openrouter_playground && node build.js",
    "server": "dune exec examples/openrouter-playground/server/main.exe"
  },
  "dependencies": {
    "@ai-sdk/react": "^1.2.12",
    "ai": "^4.3.16",
    "react": "^19.1.0",
    "react-dom": "^19.1.0"
  },
  "devDependencies": {
    "esbuild": "^0.25.0"
  }
}
```

**Step 5: Commit**

```bash
git add examples/openrouter-playground/dune examples/openrouter-playground/index.html \
  examples/openrouter-playground/build.js examples/openrouter-playground/package.json
git commit -m "feat: add OpenRouter playground client build skeleton"
```

---

### Task 3: Client -- main.mlx entry point and settings state

**Files:**
- Create: `examples/openrouter-playground/main.mlx`

The main module manages the settings state and renders the layout (chat on left, settings panel on right).

**Key design decisions:**
- Settings are stored as a record in React state
- When the user sends a message, we serialize settings to JSON and pass as `X-OpenRouter-Config` header via `send_message_with_options`
- The chat uses a single `/api/chat` endpoint
- Settings panel is collapsible

**main.mlx structure:**

```ocaml
open Ai_sdk_react

let s = React.string

(* --- Settings state --- *)

type settings = {
  model : string;
  fallback_models : string;  (* comma-separated, parsed on send *)
  web_search_enabled : bool;
  web_search_max_results : int;
  provider_order : string;   (* comma-separated *)
  provider_allow_fallbacks : bool;
  provider_sort : string;    (* "" | "price" | "throughput" | "latency" *)
  usage_enabled : bool;
  reasoning_effort : string; (* "" | "none" | "minimal" | ... | "xhigh" *)
  reasoning_max_tokens : string; (* "" or int string *)
  extra_body : string;       (* raw JSON string *)
}

let default_settings = {
  model = "openai/gpt-4o-mini";
  fallback_models = "";
  web_search_enabled = false;
  web_search_max_results = 5;
  provider_order = "";
  provider_allow_fallbacks = true;
  provider_sort = "";
  usage_enabled = false;
  reasoning_effort = "";
  reasoning_max_tokens = "";
  extra_body = "";
}

(* Serialize settings to JSON string for the X-OpenRouter-Config header *)
let settings_to_json_string (s : settings) =
  let fields = ref [ "model", `String s.model ] in
  let add key value = fields := (key, value) :: !fields in
  (* Fallback models *)
  let fallbacks =
    s.fallback_models
    |> Js.String.split ","
    |> Array.to_list
    |> List.map Js.String.trim
    |> List.filter (fun s -> String.length s > 0)
  in
  (match fallbacks with
  | [] -> ()
  | ms -> add "fallback_models" (`List (List.map (fun m -> `String m) ms)));
  (* Web search *)
  (match s.web_search_enabled with
  | true ->
    add "web_search"
      (`Assoc [ "enabled", `Bool true; "max_results", `Int s.web_search_max_results ])
  | false -> ());
  (* Provider routing *)
  let provider_order =
    s.provider_order
    |> Js.String.split ","
    |> Array.to_list
    |> List.map Js.String.trim
    |> List.filter (fun s -> String.length s > 0)
  in
  (match provider_order, s.provider_sort with
  | [], "" when s.provider_allow_fallbacks -> ()
  | _ ->
    let pfields = ref [] in
    (match provider_order with
    | [] -> ()
    | order -> pfields := ("order", `List (List.map (fun p -> `String p) order)) :: !pfields);
    (match s.provider_allow_fallbacks with
    | true -> ()
    | false -> pfields := ("allow_fallbacks", `Bool false) :: !pfields);
    (match s.provider_sort with
    | "" -> ()
    | sort -> pfields := ("sort", `String sort) :: !pfields);
    (match !pfields with
    | [] -> ()
    | fs -> add "provider" (`Assoc (List.rev fs))));
  (* Usage *)
  (match s.usage_enabled with
  | true -> add "usage" (`Bool true)
  | false -> ());
  (* Reasoning *)
  (match s.reasoning_effort, s.reasoning_max_tokens with
  | "", "" -> ()
  | effort, max_tok ->
    let rfields = ref [] in
    (match effort with
    | "" -> ()
    | e -> rfields := ("effort", `String e) :: !rfields);
    (match max_tok with
    | "" -> ()
    | n -> (try rfields := ("max_tokens", `Int (int_of_string n)) :: !rfields with _ -> ()));
    (match !rfields with
    | [] -> ()
    | fs -> add "reasoning" (`Assoc (List.rev fs))));
  (* Extra body *)
  (match s.extra_body with
  | "" -> ()
  | json_str ->
    (try add "extra_body" (Js.Json.parseExn json_str |> Obj.magic)
     with _ -> ()));
  Js.Json.stringify (Obj.magic (`Assoc (List.rev !fields)))
```

Wait -- this is Melange client-side code. We can't use `Yojson` or backtick JSON constructors on the client. We need to use `Js.Json` / `Js.Dict` / `Js.Obj`. Let me rethink.

On the Melange client side, JSON must be built using `Js.Json.t` / `Js.Dict` APIs. The `settings_to_json_string` function should use the browser's JSON APIs:

```ocaml
(* Build a Js.Json.t from settings *)
external json_stringify : Js.Json.t -> string = "stringify" [@@mel.scope "JSON"]

let settings_to_config_json (s : settings) : Js.Json.t =
  let dict = Js.Dict.empty () in
  Js.Dict.set dict "model" (Js.Json.string s.model);
  (* ... build up dict with all non-default fields ... *)
  Js.Json.object_ dict
```

This is the right approach for the client.

**The rest of main.mlx:** layout with two columns -- chat area (using `use_chat` hook directly) on the left, settings panel on the right. A custom send handler that attaches the config header.

The full implementation is large, so I'll describe the structure and the implementer should follow the patterns from `chat_layout.mlx` and `client_tools.mlx`.

**Step: Verify it compiles**

Run: `dune build @openrouter_playground 2>&1`

**Step: Commit**

---

### Task 4: Client -- settings panel component

**Files:**
- Create: `examples/openrouter-playground/settings_panel.mlx`

A collapsible panel with 6 sections, each containing form controls. Each section maps to one OpenRouter capability.

**Sections:**

1. **Model** -- text input for model ID, text input for fallback models (comma-separated)
2. **Web Search** -- checkbox toggle, number input for max_results
3. **Provider Routing** -- text input for order (comma-separated), checkbox for allow_fallbacks, select for sort
4. **Usage Tracking** -- checkbox toggle
5. **Reasoning** -- select for effort level, number input for max_tokens
6. **Extra Body** -- textarea for raw JSON

**Interface:**

```ocaml
val render :
  settings:Main.settings ->
  on_change:(Main.settings -> unit) ->
  unit ->
  React.element
```

Each control updates the parent's settings state via `on_change`.

**Step: Implement, verify build, commit**

---

### Task 5: Client -- chat integration with per-request config headers

**Files:**
- Modify: `examples/openrouter-playground/main.mlx`

Wire up the chat hook with settings:
1. Create transport with `/api/chat` endpoint
2. On send, serialize settings to JSON and pass via `X-OpenRouter-Config` header using `send_message_with_options`
3. Display messages using `Chat_message.render` from ai-e2e (or a simplified version)

Since `Chat_message` is in the ai-e2e example and not a library, we can either:
- Copy a simplified message renderer inline
- Create a shared module

For now, create a simplified inline message renderer -- the playground doesn't need the full chat_message complexity.

**Step: Implement, verify build, commit**

---

### Task 6: README

**Files:**
- Create: `examples/openrouter-playground/README.md`

Short README explaining:
- What the playground demonstrates (6 capabilities)
- How to run it (`OPENROUTER_API_KEY`, `npm install`, `npm run build`, `npm run server`)
- What each settings section does

---

### Task 7: Integration test -- verify server builds and handles config

**Step 1: Build server**

Run: `dune build examples/openrouter-playground/server/main.exe 2>&1`
Expected: builds

**Step 2: Build client (Melange emit only, skip bundle)**

Run: `dune build @openrouter_playground 2>&1`
Expected: builds (bundle requires npm install)

**Step 3: Verify full project still builds**

Run: `dune build 2>&1`
Expected: no errors

**Step 4: Run existing tests**

Run: `dune runtest 2>&1`
Expected: all pass (playground has no tests -- it's an example)

**Step 5: Commit**

```bash
git add examples/openrouter-playground/
git commit -m "feat: add OpenRouter playground example with all 6 capabilities"
```

---

## Implementation Notes

**Server-side naming:** The server's JSON config types (`playground_config`, `web_search_config`, etc.) deliberately use different names than `Openrouter_options.t` sub-types to avoid confusion. The server types are for JSON deserialization from the client; the provider types are what the SDK consumes.

**Client-side JSON:** Since this is Melange (compiles to JS), all JSON construction must use `Js.Json.t`, `Js.Dict`, etc. -- NOT `Yojson` or OCaml backtick variants.

**No new library code:** This example is purely a consumer. If the example reveals gaps in the provider API, those should be filed as issues, not fixed inline.

**Code style rules (from CLAUDE.md):**
- No `else if` -- use pattern matching
- Boolean matches: `| true -> ... | false -> ...`
- `Printf.sprintf` for multi-value strings
- Labeled args for >2 params
- Keep functions under ~50 lines
- No polymorphic compare
- No `open!` or `include` at top level
