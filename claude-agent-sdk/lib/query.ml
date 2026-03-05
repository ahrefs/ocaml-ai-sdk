let log = Devkit.Log.from "claude_agent_sdk.query"

let run ~prompt ?switch ?(options = Options.default) () =
  let span = Trace_core.enter_span ~__FILE__ ~__LINE__ "claude.run" in
  log#info "Running one-shot query with prompt: %s" (String.sub prompt 0 (min 50 (String.length prompt)));
  let%lwt transport = Transport.create ?switch ~options ~prompt () in
  let raw_stream = Transport.read_stream transport in
  let closed = ref false in
  let cleanup () =
    if not !closed then begin
      Trace_core.exit_span span;
      closed := true;
      log#info "Query stream cleanup";
      let%lwt _status = Transport.close transport in
      Lwt.return_unit
    end
    else Lwt.return_unit
  in
  let typed_stream =
    Lwt_stream.from (fun () ->
      match%lwt Lwt_stream.get raw_stream with
      | None ->
        log#info "Query stream ended";
        let%lwt () = cleanup () in
        Lwt.return_none
      | Some json ->
        Trace_core.message ~level:Debug1 "received message from claude";
        log#debug "Query received message";
        let msg = Message.of_json json in
        if Message.is_result msg then Lwt.async cleanup;
        Lwt.return_some msg)
  in
  Lwt.return typed_stream
