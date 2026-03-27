(** Custom stream composition using create_ui_message_stream.

    Demonstrates:
    - Writing custom Data parts alongside LLM output
    - Data reconciliation (same id updates the part on the client)
    - Merging a stream_text result into a composed stream
    - create_ui_message_stream_response for HTTP delivery

    Set ANTHROPIC_API_KEY environment variable before running.

    Usage:
      dune exec examples/custom_stream/main.exe

    Test with curl:
      curl -N -X POST http://localhost:28602/chat \
        -H "Content-Type: application/json" \
        -d '{"messages":[{"role":"user","parts":[{"type":"text","text":"Tell me about OCaml"}]}]}' *)

let model = Ai_provider_anthropic.model "claude-sonnet-4-6"

let handler _conn req body =
  let uri = Cohttp.Request.uri req in
  let meth = Cohttp.Request.meth req in
  match meth, Uri.path uri with
  | `OPTIONS, "/chat" -> Ai_core.Server_handler.handle_cors_preflight _conn req body
  | _, "/chat" ->
    let%lwt body_str = Cohttp_lwt.Body.to_string body in
    let body_json = try Ok (Yojson.Basic.from_string body_str) with Yojson.Json_error msg -> Error msg in
    (match body_json with
    | Error msg ->
      let body = Cohttp_lwt.Body.of_string (Printf.sprintf {|{"error":"%s"}|} msg) in
      Lwt.return (Cohttp.Response.make ~status:`Bad_request (), body)
    | Ok body_json ->
      let messages = Ai_core.Server_handler.parse_messages_from_body body_json in
      let message_id = Printf.sprintf "msg_%d" (Random.int 1_000_000) in
      let stream =
        Ai_core.Ui_message_stream_writer.create_ui_message_stream ~message_id
          ~on_finish:(fun ~finish_reason:_ ~is_aborted:_ ->
            Printf.printf "Stream finished (message_id=%s)\n%!" message_id;
            Lwt.return_unit)
          ~execute:(fun writer ->
            (* 1. Write a "loading" status data part *)
            Ai_core.Ui_message_stream_writer.write writer
              (Ai_core.Ui_message_chunk.Data
                 { data_type = "status"; id = Some "gen-status"; data = `String "generating" });
            (* 2. Start LLM generation and merge its stream *)
            let result = Ai_core.Stream_text.stream_text ~model ~messages ~system:"You are a helpful assistant." () in
            let ui_stream = Ai_core.Stream_text_result.to_ui_message_stream result in
            Ai_core.Ui_message_stream_writer.merge writer ui_stream;
            (* 3. Wait for generation to complete, then write "done" status *)
            let%lwt _usage = result.usage in
            Ai_core.Ui_message_stream_writer.write writer
              (Ai_core.Ui_message_chunk.Data { data_type = "status"; id = Some "gen-status"; data = `String "complete" });
            Lwt.return_unit)
          ()
      in
      Ai_core.Ui_message_stream_writer.create_ui_message_stream_response stream)
  | _ ->
    let body = Cohttp_lwt.Body.of_string "Not found" in
    Lwt.return (Cohttp.Response.make ~status:`Not_found (), body)

let () =
  let port = 28602 in
  Printf.printf "Custom stream example on http://localhost:%d/chat\n%!" port;
  let server =
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) (Cohttp_lwt_unix.Server.make ~callback:handler ())
  in
  Lwt_main.run server
