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
      | File _ | Source _ -> ())
    content;
  Buffer.contents text, Buffer.contents reasoning, List.rev !tool_calls

(* Runs [f ~fail_if_cancelled]. [Lwt.cancel] on the result rejects it with
   [Canceled] at once and cancels the work, but a promise that ignores
   [Lwt.cancel], such as a custom fetch or a tool built on [Lwt.wait], keeps
   the work going. [fail_if_cancelled] fails with [Canceled] after a cancel,
   so the work checks it before it starts a model request or a tool. *)
let cancelable f =
  let cancelled = ref false in
  let fail_if_cancelled () =
    match !cancelled with
    | true -> Lwt.fail Lwt.Canceled
    | false -> Lwt.return_unit
  in
  let call = Lwt.wrap_in_cancelable (f ~fail_if_cancelled) in
  Lwt.on_cancel call (fun () -> cancelled := true);
  call

(* The step a model response makes, with the results of the tools that ran. *)
let step_of_response ~text ~reasoning ~tool_calls ~tool_results (result : Ai_provider.Generate_result.t) :
  Generate_text_result.step =
  {
    text;
    reasoning;
    tool_calls;
    tool_results;
    finish_reason = result.finish_reason;
    usage = result.usage;
    response_model = result.response.model;
    provider_metadata =
      (match result.provider_metadata with
      | [] -> None
      | _ :: _ as pm -> Some pm);
  }

let is_aborted = Option.fold ~none:false ~some:Ai_provider.Abort_signal.is_aborted

(* Runs [f]. When it fails with [Aborted] because [abort_signal] fired,
   [on_abort] gets [steps ()] before the failure passes on. As in
   [stream_text], an exception from [on_abort] is ignored. *)
let reporting_abort ~abort_signal ~on_abort ~steps f =
  Lwt.catch f (fun exn ->
    (match exn with
    | Ai_provider.Abort_signal.Aborted _ when is_aborted abort_signal ->
      (try Option.iter (fun report -> report ~steps:(steps ())) on_abort with (_ : exn) -> ())
    | (_ : exn) -> ());
    Lwt.fail exn)

let generate_text ~model ?system ?system_provider_options ?prompt ?messages ?tools
  ?(tool_choice : Ai_provider.Tool_choice.t option) ?output ?(max_steps = 1) ?max_retries ?max_retry_delay_ms ?stop_when
  ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?headers ?provider_options ?on_step_finish
  ?on_abort ?telemetry ?(pending_tool_approvals = []) ?abort_signal () =
  (* Build initial messages. Tools get the step's messages without the system
     prompt, as upstream does, so the loop prepends it only for the model call. *)
  let request_messages = Prompt_builder.resolve_messages ?prompt ?messages () in
  let with_system step_messages =
    Prompt_builder.resolve_messages ?system ?system_provider_options ~messages:step_messages ()
  in
  let initial_messages = with_system request_messages in
  let mode = Output.mode_of_output output in
  let tools = Option.value ~default:[] tools in
  let provider_tools = Prompt_builder.tools_to_provider tools in
  (* Telemetry — precompute once; all values are [] / None when disabled *)
  let tp =
    Telemetry.precompute ~operation_id:"ai.generateText" ~model ?max_output_tokens ?temperature ?top_p ?top_k
      ?stop_sequences ?seed ?max_retries ?headers telemetry
  in
  let root_span_data () =
    match telemetry with
    | Some t ->
      tp.base_data
      @ Telemetry.select_attributes t
          [
            ( "ai.prompt",
              Telemetry.Input
                (fun () ->
                  `String
                    (Yojson.Basic.to_string
                       (`Assoc
                          [
                            ( "system",
                              match system with
                              | Some s -> `String s
                              | None -> `Null );
                            ( "prompt",
                              match prompt with
                              | Some p -> `String p
                              | None -> `Null );
                            "messages", `List (List.map (fun _ -> `String "<message>") initial_messages);
                          ]))) );
          ]
    | None -> []
  in
  (* Every recorded step, newest first, for [on_abort]. *)
  let recorded_steps = ref [] in
  let record_step step = recorded_steps := step :: !recorded_steps in
  cancelable @@ fun ~fail_if_cancelled ->
  reporting_abort ~abort_signal ~on_abort ~steps:(fun () -> List.rev !recorded_steps) @@ fun () ->
  (* Root span wrapping the entire operation *)
  Telemetry.maybe_span telemetry "ai.generateText" ~__FILE__ ~__LINE__ ~data:root_span_data @@ fun root_span ->
  let%lwt () =
    Telemetry.maybe_notify telemetry (fun t ->
      Telemetry.notify_on_start t
        {
          model = tp.model_info;
          messages = initial_messages;
          tools;
          function_id = tp.function_id_;
          metadata = tp.metadata_;
        })
  in
  let run_tool ~step_num ~step_messages (tc : Generate_text_result.tool_call) =
    let%lwt () = fail_if_cancelled () in
    Telemetry.maybe_span telemetry "ai.toolCall" ~__FILE__ ~__LINE__ ~data:(fun () ->
      match telemetry with
      | Some t ->
        Telemetry.tool_call_span_data ~model_info:tp.model_info ~tool_name:tc.tool_name ~tool_call_id:tc.tool_call_id
          ~args:tc.args t
      | None -> [])
    @@ fun tool_span ->
    let%lwt () =
      Telemetry.maybe_notify telemetry (fun t ->
        Telemetry.notify_on_tool_call_start t
          {
            step_number = step_num;
            model = tp.model_info;
            tool_name = tc.tool_name;
            tool_call_id = tc.tool_call_id;
            args = tc.args;
            function_id = tp.function_id_;
            metadata = tp.metadata_;
          })
    in
    let t0 = Unix.gettimeofday () in
    let%lwt tr =
      Core_tool.execute_tool ?abort_signal ~tools ~messages:step_messages ~tool_call_id:tc.tool_call_id
        ~tool_name:tc.tool_name ~args:tc.args ()
    in
    let duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
    let%lwt () =
      Telemetry.maybe_notify telemetry (fun t ->
        let outcome =
          if tr.is_error then Telemetry.Error (Yojson.Basic.to_string tr.result) else Telemetry.Success tr.result
        in
        Telemetry.notify_on_tool_call_finish t
          {
            step_number = step_num;
            model = tp.model_info;
            tool_name = tc.tool_name;
            tool_call_id = tc.tool_call_id;
            args = tc.args;
            result = outcome;
            duration_ms;
            function_id = tp.function_id_;
            metadata = tp.metadata_;
          })
    in
    (match telemetry with
    | Some t when Telemetry.enabled t ->
      Trace_core.add_data_to_span tool_span (Telemetry.tool_call_result_attrs ~result:tr.result t)
    | _ -> ());
    Lwt.return tr
  in
  (* Step loop *)
  let rec loop ~step_messages ~steps ~step_num =
    if step_num > max_steps then begin
      (* Exhausted steps - return what we have *)
      let finish_reason =
        match steps with
        | (last_step : Generate_text_result.step) :: _ -> last_step.finish_reason
        | [] -> Ai_provider.Finish_reason.Error
      in
      let steps = List.rev steps in
      Lwt.return (Final_result.make ~finish_reason ~usage:(Generate_text_result.total_usage steps) ~output:None steps)
    end
    else begin
      let current_messages = with_system step_messages in
      let opts =
        Prompt_builder.make_call_options ~messages:current_messages ~tools:provider_tools ?tool_choice ~mode
          ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?provider_options ?headers ?abort_signal
          ()
      in
      (* Step span wrapping the LLM call *)
      let%lwt result, text, reasoning, tool_calls =
        Telemetry.maybe_span telemetry "ai.generateText.doGenerate" ~__FILE__ ~__LINE__ ~data:(fun () ->
          match telemetry with
          | Some t ->
            Telemetry.step_request_attrs ~operation_id:"ai.generateText.doGenerate" ~model_info:tp.model_info
              ~current_messages ~tools ~tool_choice ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences t
          | None -> [])
        @@ fun step_span ->
        let%lwt result =
          Retry.with_retries ?abort_signal ?max_retries ?max_retry_delay_ms (fun () ->
            let%lwt () = fail_if_cancelled () in
            (* Race the call so that a model which ignores the signal in
               [opts] does not hold the call after an abort. *)
            Abort_race.race abort_signal (fun () -> Ai_provider.Language_model.generate model opts))
        in
        let text, reasoning, tool_calls = parse_content result.content in
        (* Add response attributes to step span *)
        (match telemetry with
        | Some t when Telemetry.enabled t ->
          Trace_core.add_data_to_span step_span
            (Telemetry.step_response_attrs ~text ~reasoning ~tool_calls ~finish_reason:result.finish_reason
               ~usage:result.usage ?response_id:result.response.id ?response_model:result.response.model t)
        | _ -> ());
        Lwt.return (result, text, reasoning, tool_calls)
      in
      let finished all_steps =
        Final_result.make ~response:result.response ~warnings:result.warnings ~finish_reason:result.finish_reason
          ~usage:(Generate_text_result.total_usage all_steps)
          ~output:(Output.parse_output output all_steps) all_steps
      in
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
        let%lwt blocked_calls, executable_calls = Core_tool.evaluate_approvals ~tools tool_calls in
        let%lwt batch = Tool_batch.run ~abort_signal (run_tool ~step_num ~step_messages) executable_calls in
        let tool_results = Tool_batch.results batch in
        (* The response came back, so the step counts even when an abort
           stopped its tools. The calls that did not run stay in
           [tool_calls] with no result. *)
        let step = step_of_response ~text ~reasoning ~tool_calls ~tool_results result in
        record_step step;
        let%lwt () = Tool_batch.fail_if_aborted ~abort_signal batch in
        Option.iter (fun f -> f step) on_step_finish;
        let%lwt () =
          Telemetry.maybe_notify telemetry (fun t ->
            Telemetry.notify_on_step_finish t
              { step_number = step_num; step; function_id = tp.function_id_; metadata = tp.metadata_ })
        in
        match blocked_calls with
        | _ :: _ ->
          (* Some tools need approval — stop the loop after executing ready tools *)
          Lwt.return (finished (List.rev (step :: steps)))
        | [] ->
          (* All tools executed — check stop conditions before continuing *)
          let%lwt stop_with_steps =
            match stop_when with
            | None -> Lwt.return_none
            | Some conditions ->
              let all_steps_so_far = List.rev (step :: steps) in
              let%lwt met = Stop_condition.is_met conditions ~steps:all_steps_so_far in
              Lwt.return (if met then Some all_steps_so_far else None)
          in
          (match stop_with_steps with
          | None ->
            let updated_messages =
              Prompt_builder.append_assistant_and_tool_results ~messages:step_messages ~assistant_content:result.content
                ~tool_results
            in
            let%lwt () = Ai_provider.Abort_signal.fail_if_aborted abort_signal in
            loop ~step_messages:updated_messages ~steps:(step :: steps) ~step_num:(step_num + 1)
          | Some all_steps_so_far -> Lwt.return (finished all_steps_so_far))
      end
      else begin
        (* Final step - no more tool calls *)
        let step = step_of_response ~text ~reasoning ~tool_calls ~tool_results:[] result in
        record_step step;
        Option.iter (fun f -> f step) on_step_finish;
        let%lwt () =
          Telemetry.maybe_notify telemetry (fun t ->
            Telemetry.notify_on_step_finish t
              { step_number = step_num; step; function_id = tp.function_id_; metadata = tp.metadata_ })
        in
        Lwt.return (finished (List.rev (step :: steps)))
      end
    end
  in
  (* Runs the pending tool approvals before the LLM step loop. As in a step,
     an abort that stops them still records the step with the results of the
     tools that ran. *)
  let run_pending_approvals approvals =
    let%lwt batch =
      Tool_batch.run ~abort_signal
        (fun (ta : Generate_text_result.pending_tool_approval) ->
          match ta.approved with
          | false ->
            Lwt.return
              {
                Generate_text_result.tool_call_id = ta.tool_call_id;
                tool_name = ta.tool_name;
                result = Core_tool.denied_result;
                is_error = false;
                provider_metadata = None;
              }
          | true ->
            let%lwt () = fail_if_cancelled () in
            Core_tool.execute_tool ?abort_signal ~tools ~messages:request_messages ~tool_call_id:ta.tool_call_id
              ~tool_name:ta.tool_name ~args:ta.args ())
        approvals
    in
    let tool_results = Tool_batch.results batch in
    let tool_calls =
      List.map
        (fun (ta : Generate_text_result.pending_tool_approval) ->
          { Generate_text_result.tool_call_id = ta.tool_call_id; tool_name = ta.tool_name; args = ta.args })
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
        response_model = None;
        provider_metadata = None;
      }
    in
    record_step step;
    let%lwt () = Tool_batch.fail_if_aborted ~abort_signal batch in
    Option.iter (fun f -> f step) on_step_finish;
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
    let updated_messages = request_messages @ [ Ai_provider.Prompt.Tool { content = tool_result_parts } ] in
    Lwt.return (updated_messages, [ step ])
  in
  let%lwt start_messages, initial_steps =
    match pending_tool_approvals with
    | [] -> Lwt.return (request_messages, [])
    | approvals -> run_pending_approvals approvals
  in
  let%lwt final_result =
    loop ~step_messages:start_messages ~steps:(List.rev initial_steps) ~step_num:(1 + List.length initial_steps)
  in
  (* Add final attributes to root span *)
  (match telemetry with
  | Some t when Telemetry.enabled t ->
    Trace_core.add_data_to_span root_span
      (Telemetry.final_response_attrs ~text:final_result.text ~reasoning:final_result.reasoning
         ~finish_reason:final_result.finish_reason ~usage:final_result.usage t)
  | _ -> ());
  let%lwt () =
    Telemetry.maybe_notify telemetry (fun t ->
      Telemetry.notify_on_finish t
        {
          steps = final_result.steps;
          total_usage = final_result.usage;
          finish_reason = final_result.finish_reason;
          function_id = tp.function_id_;
          metadata = tp.metadata_;
        })
  in
  Lwt.return final_result
