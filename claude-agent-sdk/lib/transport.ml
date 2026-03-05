let log = Devkit.Log.from "claude_agent_sdk.transport"

type t = {
  child_pid : int;
  stdin_fd : Lwt_unix.file_descr;
  stdin_ch : Lwt_io.output_channel;
  stdout_fd : Lwt_unix.file_descr;
  stdout_ch : Lwt_io.input_channel;
  stderr_fd : Lwt_unix.file_descr;
  write_mutex : Lwt_mutex.t;
  stream : Yojson.Safe.t Lwt_stream.t;
  push : Yojson.Safe.t option -> unit;
  mutable stdin_closed : bool;
  mutable closed : bool;
}

let find_cli_binary options =
  match options.Options.cli_path with
  | Some path -> Lwt.return path
  | None ->
    let%lwt result =
      Lwt.catch
        (fun () ->
          let%lwt output = Lwt_process.pread (Lwt_process.shell "which claude 2>/dev/null") in
          Lwt.return (String.trim output))
        (fun _exn -> Lwt.return "")
    in
    (match result with
    | path when String.length path > 0 -> Lwt.return path
    | _ ->
      let known_paths =
        [
          Filename.concat (Sys.getenv "HOME") ".local/bin/claude";
          Filename.concat (Sys.getenv "HOME") ".npm/bin/claude";
          Filename.concat (Sys.getenv "HOME") ".claude/local/claude";
          "/usr/local/bin/claude";
          "/usr/bin/claude";
        ]
      in
      let rec try_paths = function
        | [] -> Lwt.fail_with "claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
        | path :: rest -> if Sys.file_exists path then Lwt.return path else try_paths rest
      in
      try_paths known_paths)

let build_args ~(options : Options.t) =
  let acc = ref [] in
  let add flag value = acc := value :: flag :: !acc in
  let add_flag flag = acc := flag :: !acc in
  let add_opt flag = function
    | Some v -> add flag v
    | None -> ()
  in
  add "--output-format" "stream-json";
  add "--input-format" "stream-json";
  add_flag "--verbose";
  add_opt "--system-prompt" options.system_prompt;
  add_opt "--append-system-prompt" options.append_system_prompt;
  (match options.allowed_tools with
  | Some tools -> add "--allowedTools" (String.concat "," tools)
  | None -> ());
  (match options.disallowed_tools with
  | Some tools -> add "--disallowedTools" (String.concat "," tools)
  | None -> ());
  (match options.permission_mode with
  | Some mode -> add "--permission-mode" (Options.permission_mode_to_string mode)
  | None -> ());
  add_opt "--model" options.model;
  (match options.max_turns with
  | Some n -> add "--max-turns" (string_of_int n)
  | None -> ());
  (match options.max_budget_usd with
  | Some f -> add "--max-budget-usd" (Printf.sprintf "%.2f" f)
  | None -> ());
  add_opt "--resume" options.resume;
  (match options.continue_conversation with
  | Some true -> add_flag "--continue"
  | _ -> ());
  (match options.mcp_servers with
  | Some servers ->
    let json = `Assoc servers in
    add "--mcp-config" (Yojson.Safe.to_string json)
  | None -> ());
  List.rev !acc

let filter_env env_arr =
  let filtered =
    Array.to_list env_arr
    |> List.filter (fun entry -> not (String.length entry >= 10 && String.sub entry 0 10 = "CLAUDECODE"))
  in
  Array.of_list (filtered @ [ "CLAUDE_CODE_ENTRYPOINT=sdk-ocaml" ])

let push_none t = try t.push None with _ -> ()

let write_json t json =
  Lwt_mutex.with_lock t.write_mutex (fun () ->
    let line = Yojson.Safe.to_string json in
    log#debug "Sending message: %s" line;
    let%lwt () = Lwt_io.write_line t.stdin_ch line in
    Lwt_io.flush t.stdin_ch)

let end_input t =
  if t.stdin_closed then Lwt.return_unit
  else begin
    t.stdin_closed <- true;
    Lwt_mutex.with_lock t.write_mutex (fun () ->
      let%lwt () = Lwt.catch (fun () -> Lwt_io.flush t.stdin_ch) (fun _exn -> Lwt.return_unit) in
      Lwt_unix.close t.stdin_fd)
  end

let create ?switch ~options ~prompt () =
  let%lwt cli_path = find_cli_binary options in
  log#info "Found Claude CLI at: %s" cli_path;
  let args = build_args ~options in
  log#info "Starting Claude CLI with args: %s" (String.concat " " args);
  let argv = Array.of_list (cli_path :: args) in
  let env =
    let base = filter_env (Unix.environment ()) in
    match options.Options.env with
    | None -> base
    | Some extra ->
      let extra_arr = Array.of_list (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) extra) in
      Array.append base extra_arr
  in
  let cwd =
    match options.cwd with
    | Some dir -> dir
    | None -> Sys.getcwd ()
  in
  (* Set up pipes manually so closing stdin doesn't affect stdout/stderr *)
  let stdin_r, stdin_w = Unix.pipe ~cloexec:true () in
  let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
  let stderr_r, stderr_w = Unix.pipe ~cloexec:true () in
  let saved_cwd = Unix.getcwd () in
  Unix.chdir cwd;
  let child_pid = Unix.create_process_env cli_path argv env stdin_r stdout_w stderr_w in
  Unix.chdir saved_cwd;
  (* Close child-side fds in parent *)
  Unix.close stdin_r;
  Unix.close stdout_w;
  Unix.close stderr_w;
  (* Wrap parent-side fds in Lwt *)
  let stdin_fd = Lwt_unix.of_unix_file_descr ~blocking:false stdin_w in
  let stdout_fd = Lwt_unix.of_unix_file_descr ~blocking:false stdout_r in
  let stderr_fd = Lwt_unix.of_unix_file_descr ~blocking:false stderr_r in
  let stdin_ch = Lwt_io.of_fd ~mode:Lwt_io.output stdin_fd in
  let stdout_ch = Lwt_io.of_fd ~mode:Lwt_io.input stdout_fd in
  let stderr_ch = Lwt_io.of_fd ~mode:Lwt_io.input stderr_fd in
  let stream, push = Lwt_stream.create () in
  let push_safe v = try push v with _ -> () in
  let write_mutex = Lwt_mutex.create () in
  (* Background reader *)
  Lwt.async (fun () ->
    let rec loop () =
      match%lwt Lwt_io.read_line_opt stdout_ch with
      | None ->
        log#debug "Stream ended";
        push_safe None;
        Lwt.return_unit
      | Some line -> begin
        log#debug "Received message: %s" line;
        match Yojson.Safe.from_string line with
        | json ->
          push_safe (Some json);
          loop ()
        | exception e ->
          log#warn ~exn:e "Failed to parse JSON from CLI";
          loop ()
      end
    in
    Lwt.catch loop (fun exn ->
      log#warn ~exn "Background reader error";
      push_safe None;
      Lwt.return_unit));
  (* Drain stderr *)
  Lwt.async (fun () ->
    let rec loop () =
      match%lwt Lwt_io.read_line_opt stderr_ch with
      | None -> Lwt.return_unit
      | Some line ->
        log#debug "CLI stderr: %s" line;
        loop ()
    in
    Lwt.catch loop (fun exn ->
      log#debug ~exn "Stderr reader error";
      Lwt.return_unit));
  let t =
    {
      child_pid;
      stdin_fd;
      stdin_ch;
      stdout_fd;
      stdout_ch;
      stderr_fd;
      write_mutex;
      stream;
      push;
      stdin_closed = false;
      closed = false;
    }
  in
  Lwt_switch.add_hook switch (fun () ->
    if t.closed then Lwt.return_unit
    else begin
      t.closed <- true;
      let%lwt () = end_input t in
      push_none t;
      let%lwt _pid, _status = Lwt_unix.waitpid [] t.child_pid in
      Lwt.return_unit
    end);
  (* Send user message then close stdin (matching Python/TS SDK protocol) *)
  let user_message =
    `Assoc
      [
        "type", `String "user";
        "session_id", `String "";
        "message", `Assoc [ "role", `String "user"; "content", `String prompt ];
        "parent_tool_use_id", `Null;
      ]
  in
  log#info "Sending initial user prompt and closing stdin";
  let%lwt () = write_json t user_message in
  let%lwt () = end_input t in
  log#info "Transport initialized successfully (PID: %d)" child_pid;
  Lwt.return t

let read_stream t = t.stream

let close t =
  if t.closed then Lwt.return (Unix.WEXITED 0)
  else begin
    t.closed <- true;
    log#info "Closing transport (PID: %d)" t.child_pid;
    let%lwt () = end_input t in
    push_none t;
    let%lwt _pid, status = Lwt_unix.waitpid [] t.child_pid in
    log#info "Transport closed with status: %s" (match status with
      | Unix.WEXITED n -> Printf.sprintf "exited(%d)" n
      | Unix.WSIGNALED n -> Printf.sprintf "signaled(%d)" n
      | Unix.WSTOPPED n -> Printf.sprintf "stopped(%d)" n);
    Lwt.return status
  end

let pid t = t.child_pid
