let log = Devkit.Log.from "claude_agent_sdk.client"

type t = {
  options : Options.t;
  switch : Lwt_switch.t;
  mutable transport : Transport.t option;
  mutable session_id_ : string option;
  pending_requests : (string, Yojson.Safe.t Lwt.u) Hashtbl.t;
  mutable msg_stream : Message.t Lwt_stream.t;
  mutable msg_push : Message.t option -> unit;
  mutable reader_running : bool;
  request_id_counter : int ref;
}

let next_request_id t =
  let id = !(t.request_id_counter) in
  t.request_id_counter := id + 1;
  Printf.sprintf "req_%d" id

let fresh_stream t =
  let stream, push = Lwt_stream.create () in
  t.msg_stream <- stream;
  t.msg_push <- push

let extract_session_id t = function
  | Message.System s ->
    (match s.session_id with
    | Some id ->
      log#info "Session ID extracted: %s" id;
      t.session_id_ <- Some id
    | None -> ())
  | Message.Assistant a ->
    (match a.session_id with
    | Some id ->
      log#info "Session ID extracted: %s" id;
      t.session_id_ <- Some id
    | None -> ())
  | Message.Result r ->
    (match r.session_id with
    | Some id ->
      log#info "Session ID extracted: %s" id;
      t.session_id_ <- Some id
    | None -> ())
  | _ -> ()

let start_reader t transport =
  if t.reader_running then ()
  else begin
    t.reader_running <- true;
    log#info "Starting message reader";
    let raw_stream = Transport.read_stream transport in
    Lwt.async (fun () ->
      let rec loop () =
        match%lwt Lwt_stream.get raw_stream with
        | None ->
          log#info "Message reader ended";
          t.reader_running <- false;
          Lwt.return_unit
        | Some json ->
          log#debug "Processing received message";
          let msg = Message.of_json json in
          extract_session_id t msg;
          (match msg with
          | Message.Control_response cr -> begin
            log#debug "Received control_response for request_id: %s" cr.request_id;
            match Hashtbl.find_opt t.pending_requests cr.request_id with
            | Some resolver ->
              Hashtbl.remove t.pending_requests cr.request_id;
              let payload =
                match cr.result with
                | Some v -> v
                | None -> `Null
              in
              Lwt.wakeup_later resolver payload;
              loop ()
            | None ->
              log#warn "Received control_response for unknown request_id: %s" cr.request_id;
              t.msg_push (Some msg);
              loop ()
          end
          | _ ->
            t.msg_push (Some msg);
            loop ())
      in
      Lwt.catch loop (fun exn ->
        log#warn ~exn "Message reader error";
        t.reader_running <- false;
        Lwt.return_unit))
  end

let create ?(switch = Lwt_switch.create ()) ?(options = Options.default) () =
  let msg_stream, msg_push = Lwt_stream.create () in
  {
    options;
    switch;
    transport = None;
    session_id_ = None;
    pending_requests = Hashtbl.create 16;
    msg_stream;
    msg_push;
    reader_running = false;
    request_id_counter = ref 0;
  }

let close_transport t =
  match t.transport with
  | None -> Lwt.return_unit
  | Some transport ->
    t.reader_running <- false;
    t.transport <- None;
    let%lwt _status = Transport.close transport in
    Lwt.return_unit

let connect_with_opts t ~opts ~prompt =
  let span = Trace_core.enter_span ~__FILE__ ~__LINE__ "claude.connect" in
  log#info "Connecting to Claude with prompt: %s" (String.sub prompt 0 (min 50 (String.length prompt)));
  fresh_stream t;
  let%lwt transport = Transport.create ~switch:t.switch ~options:opts ~prompt () in
  t.transport <- Some transport;
  start_reader t transport;
  log#info "Client connected successfully";
  Trace_core.exit_span span;
  Lwt.return_unit

let connect t ~prompt =
  let opts =
    match t.session_id_ with
    | Some sid when t.transport <> None ->
      log#info "Connecting with session resumption: %s" sid;
      { t.options with resume = Some sid; continue_conversation = Some true }
    | _ ->
      log#info "Connecting with new session";
      t.options
  in
  connect_with_opts t ~opts ~prompt

let resume_opts t =
  match t.session_id_ with
  | Some sid -> { t.options with resume = Some sid; continue_conversation = Some true }
  | None -> t.options

let send_query t ~prompt =
  log#info "Sending new query";
  let%lwt () =
    match t.transport with
    | None -> Lwt.return_unit
    | Some _ ->
      log#info "Closing existing transport before new query";
      close_transport t
  in
  let opts = resume_opts t in
  connect_with_opts t ~opts ~prompt

let receive_messages t = t.msg_stream

let receive_until_result t =
  let rec collect acc =
    match%lwt Lwt_stream.get t.msg_stream with
    | None -> Lwt.return (List.rev acc)
    | Some msg ->
      let acc = msg :: acc in
      if Message.is_result msg then Lwt.return (List.rev acc) else collect acc
  in
  collect []

let send_control_request t request_type payload =
  match t.transport with
  | None -> Lwt.fail_with "client not connected"
  | Some transport ->
    let request_id = next_request_id t in
    log#info "Sending control request: %s (id: %s)" request_type request_id;
    let promise, resolver = Lwt.task () in
    Hashtbl.replace t.pending_requests request_id resolver;
    let json =
      `Assoc
        [
          "type", `String "control_request";
          "request_id", `String request_id;
          "request", `Assoc (("type", `String request_type) :: payload);
        ]
    in
    let%lwt () = Transport.write_json transport json in
    promise

let interrupt t =
  let%lwt _result = send_control_request t "interrupt" [] in
  Lwt.return_unit

let set_permission_mode t mode =
  let%lwt _result =
    send_control_request t "set_permission_mode" [ "permission_mode", `String (Options.permission_mode_to_string mode) ]
  in
  Lwt.return_unit

let set_model t model =
  let%lwt _result = send_control_request t "set_model" [ "model", `String model ] in
  Lwt.return_unit

let session_id t = t.session_id_

let close t =
  log#info "Closing client";
  let%lwt () = close_transport t in
  (try t.msg_push None with _ -> ());
  Lwt_switch.turn_off t.switch

let with_client ?switch ?(options = Options.default) ~prompt f =
  let client = create ?switch ~options () in
  let%lwt () = connect client ~prompt in
  Lwt.finalize (fun () -> f client) (fun () -> close client)
