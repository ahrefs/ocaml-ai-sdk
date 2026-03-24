(** Execute a single tool call, returning a tool_result. *)
let execute_tool_call ~tools (content : Ai_provider.Content.t) =
  match content with
  | Tool_call { tool_call_id; tool_name; args; _ } ->
    let args_json = Core_tool.safe_parse_json_args args in
    (match List.assoc_opt tool_name tools with
    | None ->
      Lwt.return
        {
          Generate_text_result.tool_call_id;
          tool_name;
          result = `String (Printf.sprintf "Tool '%s' not found" tool_name);
          is_error = true;
        }
    | Some (tool : Core_tool.t) ->
      Lwt.catch
        (fun () ->
          let%lwt result = tool.execute args_json in
          Lwt.return { Generate_text_result.tool_call_id; tool_name; result; is_error = false })
        (fun exn ->
          Lwt.return
            { Generate_text_result.tool_call_id; tool_name; result = `String (Printexc.to_string exn); is_error = true }))
  | Text _ | Reasoning _ | File _ -> Lwt.fail_with "execute_tool_call called with non-tool content"

(** Extract text, reasoning, and tool calls from a content list. *)
let parse_content (content : Ai_provider.Content.t list) =
  let text = Buffer.create 256 in
  let reasoning = Buffer.create 256 in
  let tool_calls = ref [] in
  List.iter
    (fun (c : Ai_provider.Content.t) ->
      match c with
      | Text { text = t } ->
        if Buffer.length text > 0 then Buffer.add_char text '\n';
        Buffer.add_string text t
      | Reasoning { text = t; _ } ->
        if Buffer.length reasoning > 0 then Buffer.add_char reasoning '\n';
        Buffer.add_string reasoning t
      | Tool_call { tool_call_id; tool_name; args; _ } ->
        let args_json = Core_tool.safe_parse_json_args args in
        tool_calls := { Generate_text_result.tool_call_id; tool_name; args = args_json } :: !tool_calls
      | File _ -> ())
    content;
  Buffer.contents text, Buffer.contents reasoning, List.rev !tool_calls

let generate_text ~model ?system ?prompt ?messages ?tools ?(tool_choice : Ai_provider.Tool_choice.t option)
  ?(max_steps = 1) ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?headers ?provider_options
  ?on_step_finish () =
  (* Build initial messages *)
  let initial_messages = Prompt_builder.resolve_messages ?system ?prompt ?messages () in
  let tools =
    match tools with
    | Some t -> t
    | None -> []
  in
  let provider_tools = Prompt_builder.tools_to_provider tools in
  (* Step loop *)
  let rec loop ~current_messages ~steps ~total_usage ~all_tool_calls ~all_tool_results ~step_num =
    if step_num > max_steps then begin
      (* Exhausted steps - return what we have *)
      let last_step =
        match steps with
        | s :: _ -> s
        | [] ->
          {
            Generate_text_result.text = "";
            reasoning = "";
            tool_calls = [];
            tool_results = [];
            finish_reason = Ai_provider.Finish_reason.Error;
            usage = { input_tokens = 0; output_tokens = 0; total_tokens = None };
          }
      in
      let rev_steps = List.rev steps in
      Lwt.return
        {
          Generate_text_result.text = Generate_text_result.join_text rev_steps;
          reasoning = Generate_text_result.join_reasoning rev_steps;
          tool_calls = List.rev all_tool_calls;
          tool_results = List.rev all_tool_results;
          steps = rev_steps;
          finish_reason = last_step.finish_reason;
          usage = total_usage;
          response = { id = None; model = None; headers = []; body = `Null };
          warnings = [];
        }
    end
    else begin
      let opts =
        Prompt_builder.make_call_options ~messages:current_messages ~tools:provider_tools ?tool_choice
          ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?provider_options ?headers ()
      in
      let%lwt result = Ai_provider.Language_model.generate model opts in
      let text, reasoning, tool_calls = parse_content result.content in
      let new_usage = Generate_text_result.add_usage total_usage result.usage in
      (* Check if we need to execute tools *)
      let has_tool_calls =
        match tool_calls with
        | [] -> false
        | _ :: _ -> true
      in
      let should_continue =
        has_tool_calls
        && step_num < max_steps
        &&
        match tool_choice with
        | Some Ai_provider.Tool_choice.None_ -> false
        | Some Auto | Some Required | Some (Specific _) | None -> true
      in
      if should_continue then begin
        (* Execute tools *)
        let tool_content =
          List.filter
            (fun (c : Ai_provider.Content.t) ->
              match c with
              | Tool_call _ -> true
              | Text _ | Reasoning _ | File _ -> false)
            result.content
        in
        let%lwt tool_results = Lwt_list.map_s (execute_tool_call ~tools) tool_content in
        let step : Generate_text_result.step =
          { text; reasoning; tool_calls; tool_results; finish_reason = result.finish_reason; usage = result.usage }
        in
        Option.iter (fun f -> f step) on_step_finish;
        (* Append assistant + tool results for next iteration *)
        let updated_messages =
          Prompt_builder.append_assistant_and_tool_results ~messages:current_messages ~assistant_content:result.content
            ~tool_results
        in
        loop ~current_messages:updated_messages ~steps:(step :: steps) ~total_usage:new_usage
          ~all_tool_calls:(List.rev_append tool_calls all_tool_calls)
          ~all_tool_results:(List.rev_append tool_results all_tool_results)
          ~step_num:(step_num + 1)
      end
      else begin
        (* Final step - no more tool calls *)
        let step : Generate_text_result.step =
          { text; reasoning; tool_calls; tool_results = []; finish_reason = result.finish_reason; usage = result.usage }
        in
        Option.iter (fun f -> f step) on_step_finish;
        let all_steps = List.rev (step :: steps) in
        Lwt.return
          {
            Generate_text_result.text = Generate_text_result.join_text all_steps;
            reasoning = Generate_text_result.join_reasoning all_steps;
            tool_calls = List.rev (List.rev_append tool_calls all_tool_calls);
            tool_results = List.rev all_tool_results;
            steps = all_steps;
            finish_reason = result.finish_reason;
            usage = new_usage;
            response = result.response;
            warnings = result.warnings;
          }
      end
    end
  in
  loop ~current_messages:initial_messages ~steps:[]
    ~total_usage:{ input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }
    ~all_tool_calls:[] ~all_tool_results:[] ~step_num:1
