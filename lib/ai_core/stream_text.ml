(* ID counter for stream blocks *)
type id_gen = {
  mutable text_count : int;
  mutable reasoning_count : int;
  mutable approval_count : int;
}

let make_id_gen () = { text_count = 0; reasoning_count = 0; approval_count = 0 }

let next_text_id gen =
  gen.text_count <- gen.text_count + 1;
  Printf.sprintf "txt_%d" gen.text_count

let next_reasoning_id gen =
  gen.reasoning_count <- gen.reasoning_count + 1;
  Printf.sprintf "rsn_%d" gen.reasoning_count

let next_approval_id gen =
  gen.approval_count <- gen.approval_count + 1;
  Printf.sprintf "appr_%d" gen.approval_count

(** Consume a provider stream for one step, emitting [Text_stream_part.t] events.
    Returns the accumulated text, reasoning, tool calls, finish reason, and usage. *)
let consume_provider_stream ~id_gen ~push ~on_chunk ?(on_text_accumulated = fun (_ : string) -> ()) provider_stream =
  let text_buf = Buffer.create 256 in
  let reasoning_buf = Buffer.create 256 in
  let current_text_id = ref None in
  let current_reasoning_id = ref None in
  (* Track tool call deltas for accumulation *)
  let tool_calls : (string, string * Buffer.t) Hashtbl.t = Hashtbl.create 4 in
  let completed_tool_calls = ref [] in
  let finish_reason = ref Ai_provider.Finish_reason.Unknown in
  let usage = ref { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = None } in
  let emit part =
    push (Some part);
    match on_chunk with
    | Some f -> f part
    | None -> ()
  in
  let close_text () =
    match !current_text_id with
    | Some id ->
      emit (Text_stream_part.Text_end { id });
      current_text_id := None
    | None -> ()
  in
  let close_reasoning () =
    match !current_reasoning_id with
    | Some id ->
      emit (Text_stream_part.Reasoning_end { id });
      current_reasoning_id := None
    | None -> ()
  in
  let%lwt () =
    Lwt_stream.iter
      (fun (part : Ai_provider.Stream_part.t) ->
        match part with
        | Stream_start _ -> ()
        | Text { text } ->
          let id =
            match !current_text_id with
            | Some id -> id
            | None ->
              close_reasoning ();
              let id = next_text_id id_gen in
              emit (Text_stream_part.Text_start { id });
              current_text_id := Some id;
              id
          in
          Buffer.add_string text_buf text;
          on_text_accumulated (Buffer.contents text_buf);
          emit (Text_stream_part.Text_delta { id; text })
        | Reasoning { text } ->
          let id =
            match !current_reasoning_id with
            | Some id -> id
            | None ->
              close_text ();
              let id = next_reasoning_id id_gen in
              emit (Text_stream_part.Reasoning_start { id });
              current_reasoning_id := Some id;
              id
          in
          Buffer.add_string reasoning_buf text;
          emit (Text_stream_part.Reasoning_delta { id; text })
        | Tool_call_delta { tool_call_id; tool_name; args_text_delta; _ } ->
          close_text ();
          close_reasoning ();
          let buf =
            match Hashtbl.find_opt tool_calls tool_call_id with
            | Some (_, buf) -> buf
            | None ->
              let buf = Buffer.create 64 in
              Hashtbl.replace tool_calls tool_call_id (tool_name, buf);
              buf
          in
          Buffer.add_string buf args_text_delta;
          emit (Text_stream_part.Tool_call_delta { tool_call_id; tool_name; args_text_delta })
        | Tool_call_finish { tool_call_id } ->
          (match Hashtbl.find_opt tool_calls tool_call_id with
          | Some (tool_name, buf) ->
            let args_str = Buffer.contents buf in
            let args = Core_tool.safe_parse_json_args args_str in
            completed_tool_calls := { Generate_text_result.tool_call_id; tool_name; args } :: !completed_tool_calls;
            emit (Text_stream_part.Tool_call { tool_call_id; tool_name; args });
            Hashtbl.remove tool_calls tool_call_id
          | None -> ())
        | Finish { finish_reason = fr; usage = u } ->
          close_text ();
          close_reasoning ();
          finish_reason := fr;
          usage := u
        | Error { error } -> emit (Text_stream_part.Error { error = Ai_provider.Provider_error.to_string error })
        | File _ | Provider_metadata _ -> ())
      provider_stream
  in
  Lwt.return
    (Buffer.contents text_buf, Buffer.contents reasoning_buf, List.rev !completed_tool_calls, !finish_reason, !usage)

let stream_text ~model ?system ?prompt ?messages ?tools ?(tool_choice : Ai_provider.Tool_choice.t option)
  ?(output : (Yojson.Basic.t, Yojson.Basic.t) Output.t option) ?(max_steps = 1) ?max_output_tokens ?temperature ?top_p
  ?top_k ?stop_sequences ?seed ?headers ?provider_options ?on_step_finish ?on_chunk ?on_finish
  ?(pending_tool_approvals = []) () =
  (* Build initial messages *)
  let initial_messages = Prompt_builder.resolve_messages ?system ?prompt ?messages () in
  let mode = Output.mode_of_output output in
  let tools =
    match tools with
    | Some t -> t
    | None -> []
  in
  let provider_tools = Prompt_builder.tools_to_provider tools in
  (* Create output streams *)
  let full_stream, full_push = Lwt_stream.create () in
  let text_stream, text_push = Lwt_stream.create () in
  let partial_output_stream, partial_output_push = Lwt_stream.create () in
  (* Promises for final values *)
  let usage_promise, usage_resolver = Lwt.wait () in
  let finish_promise, finish_resolver = Lwt.wait () in
  let steps_promise, steps_resolver = Lwt.wait () in
  let output_promise, output_resolver = Lwt.wait () in
  (* Partial output deduplication *)
  let last_partial_json = ref "" in
  let on_text_accumulated =
    match output with
    | Some o when Option.is_some o.Output.response_format ->
      fun accumulated ->
        (match o.Output.parse_partial accumulated with
        | Some json ->
          let json_str = Yojson.Basic.to_string json in
          (match String.equal json_str !last_partial_json with
          | true -> ()
          | false ->
            last_partial_json := json_str;
            partial_output_push (Some json))
        | None -> ())
    | _ -> fun (_ : string) -> ()
  in
  let id_gen = make_id_gen () in
  (* Wrapper that also pushes text to text_stream *)
  let push_full part =
    full_push part;
    match part with
    | Some (Text_stream_part.Text_delta { text; _ }) -> text_push (Some text)
    | None -> text_push None
    | _ -> ()
  in
  (* Background streaming loop *)
  Lwt.async (fun () ->
    let emit_event part =
      push_full (Some part);
      Option.iter (fun f -> f part) on_chunk
    in
    let execute_and_emit (tc : Generate_text_result.tool_call) =
      let%lwt tr = Core_tool.execute_tool ~tools ~tool_call_id:tc.tool_call_id ~tool_name:tc.tool_name ~args:tc.args in
      emit_event
        (Text_stream_part.Tool_result
           { tool_call_id = tr.tool_call_id; tool_name = tr.tool_name; result = tr.result; is_error = tr.is_error });
      Lwt.return tr
    in
    emit_event Text_stream_part.Start;
    let rec step_loop ~current_messages ~steps ~total_usage ~step_num =
      if step_num > max_steps then begin
        emit_event
          (Text_stream_part.Finish { finish_reason = Ai_provider.Finish_reason.Other "max_steps"; usage = total_usage });
        push_full None;
        partial_output_push None;
        Lwt.wakeup_later usage_resolver total_usage;
        Lwt.wakeup_later finish_resolver (Ai_provider.Finish_reason.Other "max_steps");
        Lwt.wakeup_later steps_resolver (List.rev steps);
        Lwt.wakeup_later output_resolver None;
        Lwt.return_unit
      end
      else begin
        emit_event Text_stream_part.Start_step;
        let opts =
          Prompt_builder.make_call_options ~messages:current_messages ~tools:provider_tools ?tool_choice ~mode
            ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?provider_options ?headers ()
        in
        let%lwt stream_result = Ai_provider.Language_model.stream model opts in
        let%lwt text, reasoning, tool_calls, fr, step_usage =
          consume_provider_stream ~id_gen ~push:push_full ~on_chunk ~on_text_accumulated stream_result.stream
        in
        let new_total = Generate_text_result.add_usage total_usage step_usage in
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
          let%lwt pending_approval_calls, executable_calls = Core_tool.evaluate_approvals ~tools tool_calls in
          let%lwt tool_results = Lwt_list.map_s execute_and_emit executable_calls in
          List.iter
            (fun (tc : Generate_text_result.tool_call) ->
              let approval_id = next_approval_id id_gen in
              emit_event
                (Text_stream_part.Tool_approval_request
                   { approval_id; tool_call_id = tc.tool_call_id; tool_name = tc.tool_name; args = tc.args }))
            pending_approval_calls;
          let step : Generate_text_result.step =
            { text; reasoning; tool_calls; tool_results; finish_reason = fr; usage = step_usage }
          in
          Option.iter (fun f -> f step) on_step_finish;
          emit_event (Text_stream_part.Finish_step { finish_reason = fr; usage = step_usage });
          match pending_approval_calls with
          | _ :: _ ->
            (* Some tools need approval — stop the stream *)
            emit_event (Text_stream_part.Finish { finish_reason = fr; usage = new_total });
            push_full None;
            let all_steps = List.rev (step :: steps) in
            let parsed_output = Output.parse_output output all_steps in
            partial_output_push None;
            Lwt.wakeup_later usage_resolver new_total;
            Lwt.wakeup_later finish_resolver fr;
            Lwt.wakeup_later steps_resolver all_steps;
            Lwt.wakeup_later output_resolver parsed_output;
            (match on_finish with
            | Some f ->
              let all_tool_calls = List.concat_map (fun (s : Generate_text_result.step) -> s.tool_calls) all_steps in
              let all_tool_results =
                List.concat_map (fun (s : Generate_text_result.step) -> s.tool_results) all_steps
              in
              f
                {
                  Generate_text_result.text = Generate_text_result.join_text all_steps;
                  reasoning = Generate_text_result.join_reasoning all_steps;
                  tool_calls = all_tool_calls;
                  tool_results = all_tool_results;
                  steps = all_steps;
                  finish_reason = fr;
                  usage = new_total;
                  response = { id = None; model = None; headers = []; body = `Null };
                  warnings = [];
                  output = parsed_output;
                }
            | None -> ());
            Lwt.return_unit
          | [] ->
            (* All tools executed — continue step loop *)
            let assistant_content =
              let parts = ref [] in
              if String.length text > 0 then parts := Ai_provider.Content.Text { text } :: !parts;
              List.iter
                (fun (tc : Generate_text_result.tool_call) ->
                  parts :=
                    Ai_provider.Content.Tool_call
                      {
                        tool_call_type = "function";
                        tool_call_id = tc.tool_call_id;
                        tool_name = tc.tool_name;
                        args = Yojson.Basic.to_string tc.args;
                      }
                    :: !parts)
                tool_calls;
              List.rev !parts
            in
            let updated_messages =
              Prompt_builder.append_assistant_and_tool_results ~messages:current_messages ~assistant_content
                ~tool_results
            in
            step_loop ~current_messages:updated_messages ~steps:(step :: steps) ~total_usage:new_total
              ~step_num:(step_num + 1)
        end
        else begin
          (* Final step *)
          let step : Generate_text_result.step =
            { text; reasoning; tool_calls; tool_results = []; finish_reason = fr; usage = step_usage }
          in
          Option.iter (fun f -> f step) on_step_finish;
          emit_event (Text_stream_part.Finish_step { finish_reason = fr; usage = step_usage });
          emit_event (Text_stream_part.Finish { finish_reason = fr; usage = new_total });
          push_full None;
          let all_steps = List.rev (step :: steps) in
          let parsed_output = Output.parse_output output all_steps in
          partial_output_push None;
          Lwt.wakeup_later usage_resolver new_total;
          Lwt.wakeup_later finish_resolver fr;
          Lwt.wakeup_later steps_resolver all_steps;
          Lwt.wakeup_later output_resolver parsed_output;
          (* Call on_finish if provided *)
          (match on_finish with
          | Some f ->
            let all_tool_calls = List.concat_map (fun (s : Generate_text_result.step) -> s.tool_calls) all_steps in
            let all_tool_results = List.concat_map (fun (s : Generate_text_result.step) -> s.tool_results) all_steps in
            f
              {
                Generate_text_result.text = Generate_text_result.join_text all_steps;
                reasoning = Generate_text_result.join_reasoning all_steps;
                tool_calls = all_tool_calls;
                tool_results = all_tool_results;
                steps = all_steps;
                finish_reason = fr;
                usage = new_total;
                response = { id = None; model = None; headers = []; body = `Null };
                warnings = [];
                output = parsed_output;
              }
          | None -> ());
          Lwt.return_unit
        end
      end
    in
    Lwt.catch
      (fun () ->
        (* Execute pending tool approvals before starting the LLM step loop *)
        let%lwt start_messages, initial_steps =
          match pending_tool_approvals with
          | [] -> Lwt.return (initial_messages, [])
          | approvals ->
            emit_event Text_stream_part.Start_step;
            (* Emit tool input chunks so the frontend creates tool invocations *)
            List.iter
              (fun (ta : Generate_text_result.pending_tool_approval) ->
                emit_event
                  (Text_stream_part.Tool_call
                     { tool_call_id = ta.tool_call_id; tool_name = ta.tool_name; args = ta.args }))
              approvals;
            (* Denied before approved — matches upstream emit order *)
            approvals
            |> List.filter (fun (ta : Generate_text_result.pending_tool_approval) -> not ta.approved)
            |> List.iter (fun (ta : Generate_text_result.pending_tool_approval) ->
                 emit_event
                   (Text_stream_part.Tool_output_denied { tool_call_id = ta.tool_call_id }));
            let%lwt tool_results =
              Lwt_list.map_s
                (fun (ta : Generate_text_result.pending_tool_approval) ->
                  match ta.approved with
                  | false ->
                    Lwt.return
                      {
                        Generate_text_result.tool_call_id = ta.tool_call_id;
                        tool_name = ta.tool_name;
                        result = Core_tool.denied_result;
                        is_error = false;
                      }
                  | true ->
                    execute_and_emit
                      { tool_call_id = ta.tool_call_id; tool_name = ta.tool_name; args = ta.args })
                approvals
            in
            let tool_calls =
              List.map
                (fun (ta : Generate_text_result.pending_tool_approval) ->
                  {
                    Generate_text_result.tool_call_id = ta.tool_call_id;
                    tool_name = ta.tool_name;
                    args = ta.args;
                  })
                approvals
            in
            let step : Generate_text_result.step =
              {
                text = "";
                reasoning = "";
                tool_calls;
                tool_results;
                finish_reason = Ai_provider.Finish_reason.Tool_calls;
                usage = { input_tokens = 0; output_tokens = 0; total_tokens = Some 0 };
              }
            in
            Option.iter (fun f -> f step) on_step_finish;
            emit_event
              (Text_stream_part.Finish_step
                 {
                   finish_reason = Ai_provider.Finish_reason.Tool_calls;
                   usage = { input_tokens = 0; output_tokens = 0; total_tokens = Some 0 };
                 });
            (* Append tool results to messages for the next LLM call *)
            let tool_result_parts =
              List.map
                (fun (tr : Generate_text_result.tool_result) ->
                  {
                    Ai_provider.Prompt.tool_call_id = tr.tool_call_id;
                    tool_name = tr.tool_name;
                    result = tr.result;
                    is_error = tr.is_error;
                    content = [];
                    provider_options = Ai_provider.Provider_options.empty;
                  })
                tool_results
            in
            let updated_messages =
              initial_messages @ [ Ai_provider.Prompt.Tool { content = tool_result_parts } ]
            in
            Lwt.return (updated_messages, [ step ])
        in
        step_loop ~current_messages:start_messages ~steps:(List.rev initial_steps)
          ~total_usage:{ input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }
          ~step_num:(1 + List.length initial_steps))
      (fun exn ->
        let msg = Printexc.to_string exn in
        push_full (Some (Text_stream_part.Error { error = msg }));
        push_full None;
        partial_output_push None;
        Lwt.wakeup_later_exn usage_resolver exn;
        Lwt.wakeup_later_exn finish_resolver exn;
        Lwt.wakeup_later_exn steps_resolver exn;
        Lwt.wakeup_later output_resolver None;
        Lwt.return_unit));
  {
    Stream_text_result.text_stream;
    full_stream;
    partial_output_stream;
    usage = usage_promise;
    finish_reason = finish_promise;
    steps = steps_promise;
    warnings = [];
    output = output_promise;
  }
