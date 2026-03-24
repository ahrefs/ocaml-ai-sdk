(** Chat server example using the Core SDK.

    Serves a chat endpoint compatible with useChat() from @ai-sdk/react.
    Set ANTHROPIC_API_KEY environment variable before running.

    Usage:
      dune exec examples/chat_server/main.exe

    Test with curl:
      curl -X POST http://localhost:8080/chat \
        -H "Content-Type: application/json" \
        -d '{"messages":[{"role":"user","content":"Hello!"}]}' *)

let model = Ai_provider_anthropic.model "claude-sonnet-4-6"

let weather_tool : Ai_core.Core_tool.t =
  {
    description = Some "Get the current weather for a city";
    parameters =
      `Assoc
        [
          "type", `String "object";
          "properties", `Assoc [ "city", `Assoc [ "type", `String "string"; "description", `String "The city name" ] ];
          "required", `List [ `String "city" ];
        ];
    execute =
      (fun args ->
        let city =
          try Yojson.Safe.Util.(member "city" args |> to_string) with Yojson.Safe.Util.Type_error _ -> "unknown"
        in
        Lwt.return
          (`Assoc
             [ "city", `String city; "temperature", `Int 22; "condition", `String "sunny"; "unit", `String "celsius" ]));
  }

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
        Ai_core.Server_handler.handle_chat ~model ~system:"You are a helpful assistant. Be concise."
          ~tools:[ "get_weather", weather_tool ]
          ~max_steps:3 ~send_reasoning:true conn req body)
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
  Printf.printf "Starting chat server on http://localhost:%d/chat\n%!" port;
  let server =
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) (Cohttp_lwt_unix.Server.make ~callback:handler ())
  in
  Lwt_main.run server
