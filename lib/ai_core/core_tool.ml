type execute_options = {
  tool_call_id : string;
  messages : Ai_provider.Prompt.message list;
  abort_signal : Ai_provider.Abort_signal.t option;
}

let execute_options ?abort_signal ?(messages = []) ~tool_call_id () = { tool_call_id; messages; abort_signal }

type t = {
  description : string option;
  parameters : Yojson.Basic.t;
  execute : (Yojson.Basic.t -> execute_options -> Yojson.Basic.t Lwt.t) option;
  needs_approval : (Yojson.Basic.t -> bool Lwt.t) option;
  provider_options : Ai_provider.Provider_options.t;
}

let create ?description ?needs_approval ?(provider_options = Ai_provider.Provider_options.empty) ~parameters ~execute ()
    =
  { description; parameters; execute = Some execute; needs_approval; provider_options }

let create_with_approval ?description ?(provider_options = Ai_provider.Provider_options.empty) ~parameters ~execute () =
  {
    description;
    parameters;
    execute = Some execute;
    needs_approval = Some (fun _ -> Lwt.return_true);
    provider_options;
  }

let create_client_tool ?description ?(provider_options = Ai_provider.Provider_options.empty) ~parameters () =
  { description; parameters; execute = None; needs_approval = None; provider_options }

let safe_parse_json_args s =
  match s with
  | "" -> `Assoc []
  | _ -> try Yojson.Basic.from_string s with Yojson.Json_error _ -> `String s

let denied_result = `Assoc [ "type", `String "execution-denied" ]

let execute_tool ?abort_signal ~tools ~messages ~tool_call_id ~tool_name ~args () =
  let%lwt () = Ai_provider.Abort_signal.fail_if_aborted abort_signal in
  match List.assoc_opt tool_name tools with
  | None ->
    Lwt.return
      {
        Generate_text_result.tool_call_id;
        tool_name;
        result = `String (Printf.sprintf "Tool '%s' not found" tool_name);
        is_error = true;
        provider_metadata = None;
      }
  | Some { execute = None; _ } ->
    Lwt.return
      {
        Generate_text_result.tool_call_id;
        tool_name;
        result = `String "Client-side tool — no server execute";
        is_error = true;
        provider_metadata = None;
      }
  | Some { execute = Some exec; _ } ->
    (* [wrap_in_cancelable] fails the result with [Canceled] as soon as the
       caller cancels it, so the handler below only turns the tool's own
       failures, its own [Aborted] or [Canceled] included, into a result. *)
    Lwt.wrap_in_cancelable
      (try%lwt
         let%lwt result = exec args (execute_options ?abort_signal ~messages ~tool_call_id ()) in
         Lwt.return { Generate_text_result.tool_call_id; tool_name; result; is_error = false; provider_metadata = None }
       with exn ->
         (match Call_signal.aborted abort_signal with
         | Some aborted -> Lwt.fail aborted
         | None ->
           Lwt.return
             {
               Generate_text_result.tool_call_id;
               tool_name;
               result = `String (Printexc.to_string exn);
               is_error = true;
               provider_metadata = None;
             }))

(** Partition tool calls into (blocked, executable).
    Blocked = needs approval OR client-only (no server execute).
    Executable = has execute and doesn't need approval. *)
let evaluate_approvals ~tools tool_calls =
  let%lwt results =
    Lwt_list.map_s
      (fun (tc : Generate_text_result.tool_call) ->
        let%lwt can_execute =
          match List.assoc_opt tc.tool_name tools with
          | Some { execute = None; _ } -> Lwt.return_false
          | Some { needs_approval = Some check; _ } ->
            let%lwt needs = check tc.args in
            Lwt.return (not needs)
          | Some { execute = Some _; needs_approval = None; _ } -> Lwt.return_true
          | None -> Lwt.return_false
        in
        Lwt.return (tc, can_execute))
      tool_calls
  in
  let blocked, executable =
    List.partition_map
      (fun (tc, can_execute) ->
        match can_execute with
        | true -> Right tc
        | false -> Left tc)
      results
  in
  Lwt.return (blocked, executable)
