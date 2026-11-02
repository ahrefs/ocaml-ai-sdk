type payload =
  | Text of string
  | Bytes of string

type sandbox =
  | No_sandbox
  | Landlock
  | Seccomp
  | Full

type eval_result = (payload option, string) result

type t = {
  proc : Lwt_process.process;
  max_frame_bytes : int;
  write_lock : Lwt_mutex.t;
  pending : (int, eval_result option -> unit) Hashtbl.t;
  mutable next_id : int;
  mutable dead : string option;
  mutable last_runner_error : string option;
  msg_stream : payload Lwt_stream.t;
  msg_push : payload option -> unit;
  on_log : level:string -> string -> unit;
  mutable reader : unit Lwt.t;
}

let ( let* ) = Result.bind

(* ---------- incoming frames ---------- *)

type incoming =
  | Hello of int
  | Eval_result of {
      id : int;
      result : eval_result;
    }
  | Message of payload
  | Log of {
      level : string;
      text : string;
    }
  | Runner_error of string

let exact_keys ~frame fields expected =
  let sort = List.sort String.compare in
  match List.equal String.equal (sort (List.map fst fields)) (sort expected) with
  | true -> Ok ()
  | false -> Error (Printf.sprintf "%s frame has unexpected keys [%s]" frame (String.concat "," (List.map fst fields)))

let payload_field ~frame key fields =
  match List.assoc_opt key fields with
  | Some (Cbor.Text s) -> Ok (Text s)
  | Some (Cbor.Bytes b) -> Ok (Bytes b)
  | Some (Cbor.Null | Cbor.Bool _ | Cbor.Int _ | Cbor.Array _ | Cbor.Map _) | None ->
    Error (Printf.sprintf "%s frame: %S must be text or bytes" frame key)

let text_field ~frame key fields =
  match List.assoc_opt key fields with
  | Some (Cbor.Text s) -> Ok s
  | Some (Cbor.Null | Cbor.Bool _ | Cbor.Int _ | Cbor.Bytes _ | Cbor.Array _ | Cbor.Map _) | None ->
    Error (Printf.sprintf "%s frame: %S must be text" frame key)

let int_field ~frame key fields =
  match List.assoc_opt key fields with
  | Some (Cbor.Int n) -> Ok n
  | Some (Cbor.Null | Cbor.Bool _ | Cbor.Text _ | Cbor.Bytes _ | Cbor.Array _ | Cbor.Map _) | None ->
    Error (Printf.sprintf "%s frame: %S must be an integer" frame key)

let bool_field ~frame key fields =
  match List.assoc_opt key fields with
  | Some (Cbor.Bool b) -> Ok b
  | Some (Cbor.Null | Cbor.Int _ | Cbor.Text _ | Cbor.Bytes _ | Cbor.Array _ | Cbor.Map _) | None ->
    Error (Printf.sprintf "%s frame: %S must be a boolean" frame key)

let parse_eval_result fields =
  let frame = "eval_result" in
  let* id = int_field ~frame "id" fields in
  let* ok = bool_field ~frame "ok" fields in
  match ok with
  | true ->
    let* () = exact_keys ~frame fields [ "t"; "id"; "ok"; "value" ] in
    (match List.assoc_opt "value" fields with
    | Some Cbor.Null -> Ok (Eval_result { id; result = Ok None })
    | Some (Cbor.Text s) -> Ok (Eval_result { id; result = Ok (Some (Text s)) })
    | Some (Cbor.Bytes b) -> Ok (Eval_result { id; result = Ok (Some (Bytes b)) })
    | Some (Cbor.Bool _ | Cbor.Int _ | Cbor.Array _ | Cbor.Map _) | None ->
      Error "eval_result frame: \"value\" must be text, bytes or null")
  | false ->
    let* () = exact_keys ~frame fields [ "t"; "id"; "ok"; "error" ] in
    let* error = text_field ~frame "error" fields in
    Ok (Eval_result { id; result = Error error })

let parse_incoming = function
  | Cbor.Map fields ->
    (match List.assoc_opt "t" fields with
    | Some (Cbor.Text "hello") ->
      let* () = exact_keys ~frame:"hello" fields [ "t"; "proto" ] in
      let* proto = int_field ~frame:"hello" "proto" fields in
      Ok (Hello proto)
    | Some (Cbor.Text "eval_result") -> parse_eval_result fields
    | Some (Cbor.Text "message") ->
      let* () = exact_keys ~frame:"message" fields [ "t"; "data" ] in
      let* data = payload_field ~frame:"message" "data" fields in
      Ok (Message data)
    | Some (Cbor.Text "log") ->
      let* () = exact_keys ~frame:"log" fields [ "t"; "level"; "text" ] in
      let* level = text_field ~frame:"log" "level" fields in
      let* text = text_field ~frame:"log" "text" fields in
      Ok (Log { level; text })
    | Some (Cbor.Text "error") ->
      let* () = exact_keys ~frame:"error" fields [ "t"; "message" ] in
      let* message = text_field ~frame:"error" "message" fields in
      Ok (Runner_error message)
    | Some (Cbor.Text other) -> Error (Printf.sprintf "unknown frame type %S" other)
    | Some (Cbor.Null | Cbor.Bool _ | Cbor.Int _ | Cbor.Bytes _ | Cbor.Array _ | Cbor.Map _) | None ->
      Error "frame has no text \"t\" key")
  | Cbor.Null | Cbor.Bool _ | Cbor.Int _ | Cbor.Text _ | Cbor.Bytes _ | Cbor.Array _ -> Error "frame is not a map"

let read_incoming ~max_frame_bytes ic =
  match%lwt Frame.read ~max_frame_bytes ic with
  | Error e -> Lwt.return (Error (Printf.sprintf "framing error: %s" e))
  | Ok None -> Lwt.return (Ok None)
  | Ok (Some payload) ->
    Lwt.return
      (let* cbor = Result.map_error (Printf.sprintf "invalid CBOR: %s") (Cbor.decode payload) in
       let* frame = parse_incoming cbor in
       Ok (Some frame))

(* ---------- process lifecycle ---------- *)

let kill_process (proc : Lwt_process.process) = try proc#kill Sys.sigkill with Unix.Unix_error _ -> ()

let wait_status ~grace_s (proc : Lwt_process.process) =
  try%lwt Lwt_unix.with_timeout grace_s (fun () -> Lwt.protected proc#status)
  with Lwt_unix.Timeout ->
    kill_process proc;
    proc#status

let signal_name s =
  let known =
    [
      Sys.sigkill, "SIGKILL";
      Sys.sigsegv, "SIGSEGV";
      Sys.sigabrt, "SIGABRT";
      Sys.sigterm, "SIGTERM";
      Sys.sigint, "SIGINT";
      Sys.sigpipe, "SIGPIPE";
      Sys.sigxcpu, "SIGXCPU";
      Sys.sigsys, "SIGSYS";
    ]
  in
  match List.assoc_opt s known with
  | Some name -> name
  | None -> Printf.sprintf "signal %d" s

let describe_status = function
  | Unix.WEXITED n -> Printf.sprintf "exit status %d" n
  | Unix.WSIGNALED s -> Printf.sprintf "killed by %s" (signal_name s)
  | Unix.WSTOPPED s -> Printf.sprintf "stopped by %s" (signal_name s)

(* Called once, by the reader, when the stream is over. *)
let finish t ~reason ~kill =
  if kill then kill_process t.proc;
  let%lwt status = wait_status ~grace_s:5. t.proc in
  let runner_error = Option.fold ~none:"" ~some:(Printf.sprintf " (runner reported: %s)") t.last_runner_error in
  let msg = Printf.sprintf "VM is dead: %s%s; %s" reason runner_error (describe_status status) in
  t.dead <- Some msg;
  let waiters = Hashtbl.fold (fun _ resolve acc -> resolve :: acc) t.pending [] in
  Hashtbl.reset t.pending;
  List.iter (fun resolve -> resolve (Some (Error msg))) waiters;
  t.msg_push None;
  Lwt.return_unit

let handle t = function
  | Message data ->
    t.msg_push (Some data);
    Ok ()
  | Log { level; text } ->
    (try t.on_log ~level text with _ -> ());
    Ok ()
  | Runner_error msg ->
    t.last_runner_error <- Some msg;
    Ok ()
  | Eval_result { id; result } ->
    (match Hashtbl.find_opt t.pending id with
    | Some resolve ->
      Hashtbl.remove t.pending id;
      resolve (Some result);
      Ok ()
    | None -> Error (Printf.sprintf "eval_result for unknown id %d" id))
  | Hello _ -> Error "unexpected second hello frame"

let rec read_loop t =
  match%lwt read_incoming ~max_frame_bytes:t.max_frame_bytes t.proc#stdout with
  | Error e -> finish t ~reason:(Printf.sprintf "protocol violation: %s" e) ~kill:true
  | Ok None -> finish t ~reason:"runner closed stdout" ~kill:false
  | Ok (Some frame) ->
  match handle t frame with
  | Ok () -> read_loop t
  | Error e -> finish t ~reason:(Printf.sprintf "protocol violation: %s" e) ~kill:true

(* ---------- spawn ---------- *)

let sandbox_arg = function
  | No_sandbox -> "none"
  | Landlock -> "landlock"
  | Seccomp -> "seccomp"
  | Full -> "full"

let build_args ?sandbox ~memory_limit_mb ?cpu_seconds ?max_frame_bytes ~allow_clock ~allow_random () =
  List.concat
    [
      Option.fold ~none:[] ~some:(fun s -> [ "--sandbox"; sandbox_arg s ]) sandbox;
      [ "--memory-limit-mb"; string_of_int memory_limit_mb ];
      Option.fold ~none:[] ~some:(fun n -> [ "--cpu-seconds"; string_of_int n ]) cpu_seconds;
      Option.fold ~none:[] ~some:(fun n -> [ "--max-frame-bytes"; string_of_int n ]) max_frame_bytes;
      (match allow_clock with
      | true -> [ "--allow-clock" ]
      | false -> []);
      (match allow_random with
      | true -> [ "--allow-random" ]
      | false -> []);
    ]

let handshake_timeout_s = 30.

let close_channels (proc : Lwt_process.process) =
  let quiet ch = try%lwt ch () with Unix.Unix_error _ | Lwt_io.Channel_closed _ | Sys_error _ -> Lwt.return_unit in
  let%lwt () = quiet (fun () -> Lwt_io.close proc#stdin) in
  quiet (fun () -> Lwt_io.close proc#stdout)

let fail_handshake proc reason =
  kill_process proc;
  let%lwt status = wait_status ~grace_s:5. proc in
  let%lwt () = close_channels proc in
  Lwt.return (Error (Printf.sprintf "handshake failed: %s; %s" reason (describe_status status)))

let expect_hello ~max_frame_bytes (proc : Lwt_process.process) =
  let%lwt first =
    try%lwt Lwt_unix.with_timeout handshake_timeout_s (fun () -> read_incoming ~max_frame_bytes proc#stdout)
    with Lwt_unix.Timeout -> Lwt.return (Error "timeout waiting for hello")
  in
  Lwt.return
    (match first with
    | Ok (Some (Hello 1)) -> Ok ()
    | Ok (Some (Hello n)) -> Error (Printf.sprintf "unsupported protocol version %d" n)
    | Ok (Some (Runner_error msg)) -> Error (Printf.sprintf "runner reported: %s" msg)
    | Ok (Some (Eval_result _ | Message _ | Log _)) -> Error "first frame is not hello"
    | Ok None -> Error "runner closed stdout before hello"
    | Error e -> Error e)

let spawn ~binary ?sandbox ~memory_limit_mb ?cpu_seconds ?(max_frame_bytes = Frame.default_max_frame_bytes)
  ?(allow_clock = false) ?(allow_random = false) ?(on_log = fun ~level:_ _ -> ()) () =
  match memory_limit_mb > 0, max_frame_bytes >= 1 && max_frame_bytes <= Frame.max_allowed_frame_bytes with
  | false, _ -> Lwt.return (Error "memory_limit_mb must be positive")
  | _, false -> Lwt.return (Error "max_frame_bytes must be in 1 .. 1073741824")
  | true, true ->
    Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
    let args = build_args ?sandbox ~memory_limit_mb ?cpu_seconds ~max_frame_bytes ~allow_clock ~allow_random () in
    (match Lwt_process.open_process ~stderr:`Dev_null (binary, Array.of_list (binary :: args)) with
    | exception Unix.Unix_error (e, fn, _) ->
      Lwt.return (Error (Printf.sprintf "cannot start %s: %s: %s" binary fn (Unix.error_message e)))
    | proc ->
    match%lwt expect_hello ~max_frame_bytes proc with
    | Error reason -> fail_handshake proc reason
    | Ok () ->
      let msg_stream, msg_push = Lwt_stream.create () in
      let t =
        {
          proc;
          max_frame_bytes;
          write_lock = Lwt_mutex.create ();
          pending = Hashtbl.create 16;
          next_id = 1;
          dead = None;
          last_runner_error = None;
          msg_stream;
          msg_push;
          on_log;
          reader = Lwt.return_unit;
        }
      in
      (* The reader is a plain promise owned by [t] and awaited by [close]; it never fails. *)
      t.reader <- read_loop t;
      Lwt.return (Ok t))

(* ---------- operations ---------- *)

(* Writes are serialised and shielded from cancellation: a half-written frame would corrupt the stream. *)
let write_frame t cbor =
  let payload = Cbor.encode cbor in
  Lwt.no_cancel
    (Lwt_mutex.with_lock t.write_lock (fun () ->
       match%lwt Frame.write ~max_frame_bytes:t.max_frame_bytes t.proc#stdin payload with
       | Ok () -> Lwt.return (Ok ())
       | Error (Frame.Too_large _ | Frame.Empty) as e -> Lwt.return e
       | Error (Frame.Io_error _) as e ->
         (* the stream may be corrupt: end the VM, which also fails pending evals *)
         kill_process t.proc;
         Lwt.return e))

let dead_error t = Option.map (fun m -> Error m) t.dead

let eval t code =
  match dead_error t, String.is_valid_utf_8 code with
  | Some e, _ -> Lwt.return e
  | None, false -> Lwt.return (Error "code is not valid UTF-8")
  | None, true ->
    let id = t.next_id in
    t.next_id <- id + 1;
    let answers, push = Lwt_stream.create () in
    Hashtbl.replace t.pending id push;
    let frame = Cbor.Map [ "t", Cbor.Text "eval"; "id", Cbor.Int id; "code", Cbor.Text code ] in
    (match%lwt write_frame t frame with
    | Error e ->
      Hashtbl.remove t.pending id;
      Lwt.return (Error (Frame.string_of_write_error e))
    | Ok () ->
    match%lwt Lwt_stream.get answers with
    | Some r -> Lwt.return r
    | None -> Lwt.return (Error "eval abandoned"))

let send t data =
  let field =
    match data with
    | Text s -> Cbor.Text s
    | Bytes b -> Cbor.Bytes b
  in
  match t.dead, data with
  | Some m, _ -> Lwt.fail_with m
  | None, Text s when not (String.is_valid_utf_8 s) -> invalid_arg "Vm.send: text is not valid UTF-8"
  | None, (Text _ | Bytes _) ->
  match%lwt write_frame t (Cbor.Map [ "t", Cbor.Text "message"; "data", field ]) with
  | Ok () -> Lwt.return_unit
  | Error ((Frame.Too_large _ | Frame.Empty) as e) -> Lwt.fail (Invalid_argument (Frame.string_of_write_error e))
  | Error (Frame.Io_error _ as e) -> Lwt.fail_with (Frame.string_of_write_error e)

let messages t = t.msg_stream
let is_alive t = Option.is_none t.dead

let close ?(grace_s = 2.) t =
  let stdin_closed =
    try%lwt Lwt_io.close t.proc#stdin
    with Unix.Unix_error _ | Lwt_io.Channel_closed _ | Sys_error _ -> Lwt.return_unit
  in
  let%lwt status = wait_status ~grace_s t.proc in
  let%lwt () = stdin_closed in
  let%lwt () = t.reader in
  let%lwt () = close_channels t.proc in
  Lwt.return status

let kill t =
  kill_process t.proc;
  let%lwt status = t.proc#status in
  let%lwt () = t.reader in
  let%lwt () = close_channels t.proc in
  Lwt.return status
