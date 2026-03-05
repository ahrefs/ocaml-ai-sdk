(** Chat server example using the Core SDK.

    Serves a chat endpoint compatible with useChat() from @ai-sdk/react.
    Set ANTHROPIC_API_KEY environment variable before running.

    Usage:
      dune exec examples/chat_server.exe

    Test with curl:
      curl -X POST http://localhost:8080/chat \
        -H "Content-Type: application/json" \
        -d '{"messages":[{"role":"user","content":"Hello!"}]}'

    Or connect a React frontend using useChat():
      const { messages, input, handleSubmit } = useChat({
        api: 'http://localhost:8080/chat',
      }); *)

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
        let city = try Yojson.Safe.Util.(member "city" args |> to_string) with _ -> "unknown" in
        Lwt.return
          (`Assoc
             [ "city", `String city; "temperature", `Int 22; "condition", `String "sunny"; "unit", `String "celsius" ]));
  }

let handler _conn req body =
  let uri = Cohttp.Request.uri req in
  let path = Uri.path uri in
  match path with
  | "/chat" ->
    Ai_core.Server_handler.handle_chat ~model ~system:"You are a helpful assistant. Be concise."
      ~tools:[ "get_weather", weather_tool ]
      ~max_steps:3 ~send_reasoning:true _conn req body
  | _ ->
    let body = Cohttp_lwt.Body.of_string "Not found" in
    let headers = Cohttp.Header.of_list [ "content-type", "text/plain" ] in
    let response = Cohttp.Response.make ~status:`Not_found ~headers () in
    Lwt.return (response, body)

let () =
  let port = 8080 in
  Printf.printf "Starting chat server on http://localhost:%d/chat\n%!" port;
  let server =
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) (Cohttp_lwt_unix.Server.make ~callback:handler ())
  in
  Lwt_main.run server
