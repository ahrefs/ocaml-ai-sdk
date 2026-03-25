(* ID counter for stream blocks *)
type id_gen = {
  mutable text_count : int;
  mutable reasoning_count : int;
}

let make_id_gen () = { text_count = 0; reasoning_count = 0 }

let next_text_id gen =
  gen.text_count <- gen.text_count + 1;
  Printf.sprintf "txt_%d" gen.text_count

let next_reasoning_id gen =
  gen.reasoning_count <- gen.reasoning_count + 1;
  Printf.sprintf "rsn_%d" gen.reasoning_count

(** Consume a provider stream for one step, emitting [Text_stream_part.t] events.
    Returns the accumulated text, reasoning, tool calls, finish reason, and usage. *)
let consume_provider_stream ~id_gen ~push ~on_chunk provider_stream =
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
  ?(max_steps = 1) ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?headers ?provider_options
  ?on_step_finish ?on_chunk ?on_finish () =
  (* Build initial messages *)
  let initial_messages = Prompt_builder.resolve_messages ?system ?prompt ?messages () in
  let tools =
    match tools with
    | Some t -> t
    | None -> []
  in
  let provider_tools = Prompt_builder.tools_to_provider tools in
  (* Create output streams *)
  let full_stream, full_push = Lwt_stream.create () in
  let text_stream, text_push = Lwt_stream.create () in
  (* Promises for final values *)
  let usage_promise, usage_resolver = Lwt.wait () in
  let finish_promise, finish_resolver = Lwt.wait () in
  let steps_promise, steps_resolver = Lwt.wait () in
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
    emit_event Text_stream_part.Start;
    let rec step_loop ~current_messages ~steps ~total_usage ~step_num =
      if step_num > max_steps then begin
        emit_event
          (Text_stream_part.Finish { finish_reason = Ai_provider.Finish_reason.Other "max_steps"; usage = total_usage });
        push_full None;
        Lwt.wakeup_later usage_resolver total_usage;
        Lwt.wakeup_later finish_resolver (Ai_provider.Finish_reason.Other "max_steps");
        Lwt.wakeup_later steps_resolver (List.rev steps);
        Lwt.return_unit
      end
      else begin
        emit_event Text_stream_part.Start_step;
        let opts =
          Prompt_builder.make_call_options ~messages:current_messages ~tools:provider_tools ?tool_choice
            ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?provider_options ?headers ()
        in
        let%lwt stream_result = Ai_provider.Language_model.stream model opts in
        let%lwt text, reasoning, tool_calls, fr, step_usage =
          consume_provider_stream ~id_gen ~push:push_full ~on_chunk stream_result.stream
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
          (* Execute tools *)
          let%lwt tool_results =
            Lwt_list.map_s
              (fun (tc : Generate_text_result.tool_call) ->
                match List.assoc_opt tc.tool_name tools with
                | None ->
                  let tr =
                    {
                      Generate_text_result.tool_call_id = tc.tool_call_id;
                      tool_name = tc.tool_name;
                      result = `String (Printf.sprintf "Tool '%s' not found" tc.tool_name);
                      is_error = true;
                    }
                  in
                  emit_event
                    (Text_stream_part.Tool_result
                       { tool_call_id = tc.tool_call_id; tool_name = tc.tool_name; result = tr.result; is_error = true });
                  Lwt.return tr
                | Some (tool : Core_tool.t) ->
                  Lwt.catch
                    (fun () ->
                      let%lwt result = tool.execute tc.args in
                      let tr =
                        {
                          Generate_text_result.tool_call_id = tc.tool_call_id;
                          tool_name = tc.tool_name;
                          result;
                          is_error = false;
                        }
                      in
                      emit_event
                        (Text_stream_part.Tool_result
                           { tool_call_id = tc.tool_call_id; tool_name = tc.tool_name; result; is_error = false });
                      Lwt.return tr)
                    (fun exn ->
                      let err = `String (Printexc.to_string exn) in
                      let tr =
                        {
                          Generate_text_result.tool_call_id = tc.tool_call_id;
                          tool_name = tc.tool_name;
                          result = err;
                          is_error = true;
                        }
                      in
                      emit_event
                        (Text_stream_part.Tool_result
                           { tool_call_id = tc.tool_call_id; tool_name = tc.tool_name; result = err; is_error = true });
                      Lwt.return tr))
              tool_calls
          in
          let step : Generate_text_result.step =
            { text; reasoning; tool_calls; tool_results; finish_reason = fr; usage = step_usage }
          in
          Option.iter (fun f -> f step) on_step_finish;
          emit_event (Text_stream_part.Finish_step { finish_reason = fr; usage = step_usage });
          (* Build messages for next step *)
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
            Prompt_builder.append_assistant_and_tool_results ~messages:current_messages ~assistant_content ~tool_results
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
          Lwt.wakeup_later usage_resolver new_total;
          Lwt.wakeup_later finish_resolver fr;
          let all_steps = List.rev (step :: steps) in
          Lwt.wakeup_later steps_resolver all_steps;
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
                output = None;
              }
          | None -> ());
          Lwt.return_unit
        end
      end
    in
    Lwt.catch
      (fun () ->
        step_loop ~current_messages:initial_messages ~steps:[]
          ~total_usage:{ input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }
          ~step_num:1)
      (fun exn ->
        let msg = Printexc.to_string exn in
        push_full (Some (Text_stream_part.Error { error = msg }));
        push_full None;
        Lwt.wakeup_later_exn usage_resolver exn;
        Lwt.wakeup_later_exn finish_resolver exn;
        Lwt.wakeup_later_exn steps_resolver exn;
        Lwt.return_unit));
  {
    Stream_text_result.text_stream;
    full_stream;
    usage = usage_promise;
    finish_reason = finish_promise;
    steps = steps_promise;
    warnings = [];
  }
