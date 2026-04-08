type t = {
  description : string option;
  parameters : Yojson.Basic.t;
  execute : (Yojson.Basic.t -> Yojson.Basic.t Lwt.t) option;
  needs_approval : (Yojson.Basic.t -> bool Lwt.t) option;
}

let create ?description ?needs_approval ~parameters ~execute () =
  { description; parameters; execute = Some execute; needs_approval }

let create_with_approval ?description ~parameters ~execute () =
  { description; parameters; execute = Some execute; needs_approval = Some (fun _ -> Lwt.return_true) }

let create_client_tool ?description ~parameters () = { description; parameters; execute = None; needs_approval = None }

let safe_parse_json_args s =
  match s with
  | "" -> `Assoc []
  | _ -> try Yojson.Basic.from_string s with Yojson.Json_error _ -> `String s

let denied_result = `Assoc [ "type", `String "execution-denied" ]

let execute_tool ~tools ~tool_call_id ~tool_name ~args =
  match List.assoc_opt tool_name tools with
  | None ->
    Lwt.return
      {
        Generate_text_result.tool_call_id;
        tool_name;
        result = `String (Printf.sprintf "Tool '%s' not found" tool_name);
        is_error = true;
      }
  | Some { execute = None; _ } ->
    Lwt.return
      {
        Generate_text_result.tool_call_id;
        tool_name;
        result = `String "Client-side tool — no server execute";
        is_error = true;
      }
  | Some { execute = Some exec; _ } ->
  try%lwt
    let%lwt result = exec args in
    Lwt.return { Generate_text_result.tool_call_id; tool_name; result; is_error = false }
  with exn ->
    Lwt.return
      { Generate_text_result.tool_call_id; tool_name; result = `String (Printexc.to_string exn); is_error = true }

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
