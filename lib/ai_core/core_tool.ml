type t = {
  description : string option;
  parameters : Yojson.Basic.t;
  execute : Yojson.Basic.t -> Yojson.Basic.t Lwt.t;
  needs_approval : (Yojson.Basic.t -> bool Lwt.t) option;
}

let create ?description ?needs_approval ~parameters ~execute () = { description; parameters; execute; needs_approval }

let create_with_approval ?description ~parameters ~execute () =
  { description; parameters; execute; needs_approval = Some (fun _ -> Lwt.return_true) }

let safe_parse_json_args s = try Yojson.Basic.from_string s with Yojson.Json_error _ -> `String s

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
  | Some (tool : t) ->
    Lwt.catch
      (fun () ->
        let%lwt result = tool.execute args in
        Lwt.return { Generate_text_result.tool_call_id; tool_name; result; is_error = false })
      (fun exn ->
        Lwt.return
          { Generate_text_result.tool_call_id; tool_name; result = `String (Printexc.to_string exn); is_error = true })

let evaluate_approvals ~tools tool_calls =
  let%lwt results =
    Lwt_list.map_s
      (fun (tc : Generate_text_result.tool_call) ->
        let%lwt needs =
          match List.assoc_opt tc.tool_name tools with
          | Some tool ->
            (match tool.needs_approval with
            | Some check -> check tc.args
            | None -> Lwt.return_false)
          | None -> Lwt.return_false
        in
        Lwt.return (tc, needs))
      tool_calls
  in
  let pending, ready =
    List.partition_map
      (fun (tc, needs) ->
        match needs with
        | true -> Left tc
        | false -> Right tc)
      results
  in
  Lwt.return (pending, ready)
