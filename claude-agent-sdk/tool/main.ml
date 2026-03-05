open Claude_agent_sdk

let () =
  let prompt = ref "" in
  let model = ref "sonnet" in
  let permission_mode = ref "default" in
  let max_turns = ref 0 in
  let resume = ref "" in
  let spec =
    [
      "-p", Arg.Set_string prompt, "Prompt to send";
      "--model", Arg.Set_string model, "Model to use (default: sonnet)";
      "--permission-mode", Arg.Set_string permission_mode, "Permission mode";
      "--max-turns", Arg.Set_int max_turns, "Max turns (0 = unlimited)";
      "--resume", Arg.Set_string resume, "Session ID to resume";
    ]
  in
  Arg.parse spec (fun s -> prompt := s) "claude-agent-sdk-tool [OPTIONS]";
  if !prompt = "" then begin
    Printf.eprintf "Usage: claude-agent-sdk-tool -p <prompt>\n";
    exit 1
  end;
  let perm_mode =
    match !permission_mode with
    | "acceptEdits" -> Some Options.Accept_edits
    | "plan" -> Some Options.Plan
    | "bypassPermissions" -> Some Options.Bypass_permissions
    | "default" -> Some Options.Default
    | _ -> None
  in
  let options =
    {
      Options.default with
      model = Some !model;
      permission_mode = perm_mode;
      max_turns = (if !max_turns > 0 then Some !max_turns else None);
      resume = (if !resume <> "" then Some !resume else None);
    }
  in
  Lwt_main.run
    begin
      let%lwt messages = Query.run ~prompt:!prompt ~options () in
      Lwt_stream.iter_s
        (fun msg ->
          (match msg with
          | Message.System s ->
            Printf.printf "[system] subtype=%s" s.subtype;
            CCOption.iter (Printf.printf " session=%s") s.session_id;
            CCOption.iter (Printf.printf " model=%s") s.model;
            print_newline ()
          | Message.Assistant a ->
            List.iter
              (function
                | Types.Text { text } -> print_string text
                | Types.Thinking { thinking; _ } -> Printf.printf "[thinking] %s\n" thinking
                | Types.Tool_use { name; _ } -> Printf.printf "[tool_use] %s\n" name
                | Types.Tool_result { content; _ } ->
                  Printf.printf "[tool_result] %s\n" (String.sub content 0 (min 200 (String.length content))))
              a.message.content
          | Message.Result r ->
            print_newline ();
            Printf.printf "[result] subtype=%s" r.subtype;
            CCOption.iter (Printf.printf " cost=$%.4f") r.total_cost_usd;
            CCOption.iter (fun n -> Printf.printf " turns=%d" n) r.num_turns;
            print_newline ()
          | Message.Unknown json -> Printf.printf "[unknown] %s\n" (Yojson.Safe.to_string json)
          | _ -> ());
          Lwt.return_unit)
        messages
    end
