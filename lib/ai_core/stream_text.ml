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

(* The next provider part, or [None] once [signal] fires. The read stops even
   when the provider ignores the signal and never pushes again. Cancelling the
   pending [Lwt_stream.get] loses no part: a part pushed later stays in the
   stream. *)
let next_part_until_abort signal provider_stream =
  let%lwt part =
    Lwt.pick
      [
        Lwt_stream.get provider_stream;
        (let%lwt () = Ai_provider.Abort_signal.wait signal in
         Lwt.return_none);
      ]
  in
  match part with
  | Some (_ : Ai_provider.Stream_part.t) when Ai_provider.Abort_signal.is_aborted signal -> Lwt.return_none
  | Some _ | None -> Lwt.return part

(** Consume a provider stream for one step, emitting [Text_stream_part.t] events.
    Returns the accumulated text, reasoning blocks, tool calls, finish reason, and usage.
    Stops reading, and returns what it has, once [abort_signal] has fired. *)
let consume_provider_stream ?abort_signal ?(on_text_accumulated = fun (_ : string) -> ()) ~id_gen ~emit provider_stream
    =
  let provider_stream =
    match abort_signal with
    | None -> provider_stream
    | Some signal -> Lwt_stream.from (fun () -> next_part_until_abort signal provider_stream)
  in
  let text_buf = Buffer.create 256 in
  let reasoning_buf = Buffer.create 256 in
  let current_reasoning_text = Buffer.create 256 in
  let current_reasoning_signature = ref None in
  let current_reasoning_provider_options = ref Ai_provider.Provider_options.empty in
  let current_reasoning_provider_metadata = ref None in
  let reasoning_content = ref [] in
  let current_text_id = ref None in
  let current_reasoning_id = ref None in
  (* Track tool call deltas for accumulation *)
  let tool_calls : (string, string * Buffer.t) Hashtbl.t = Hashtbl.create 4 in
  let completed_tool_calls = ref [] in
  let finish_reason = ref Ai_provider.Finish_reason.Unknown in
  let usage = ref { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = None } in
  let provider_metadata : Ai_provider.Provider_options.t option ref = ref None in
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
      reasoning_content :=
        Ai_provider.Content.Reasoning
          {
            text = Buffer.contents current_reasoning_text;
            signature = !current_reasoning_signature;
            provider_options = !current_reasoning_provider_options;
          }
        :: !reasoning_content;
      emit (Text_stream_part.Reasoning_end { id; provider_metadata = !current_reasoning_provider_metadata });
      current_reasoning_id := None;
      Buffer.clear current_reasoning_text;
      current_reasoning_signature := None;
      current_reasoning_provider_options := Ai_provider.Provider_options.empty;
      current_reasoning_provider_metadata := None
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
        | Reasoning { text; signature; provider_options } ->
          let reasoning_metadata = Ai_provider.Provider_options.provider_metadata provider_options in
          let metadata_only = String.equal text "" && Option.is_none signature && Option.is_some reasoning_metadata in
          let id =
            match !current_reasoning_id with
            | Some id -> id
            | None ->
              close_text ();
              let id = next_reasoning_id id_gen in
              emit (Text_stream_part.Reasoning_start { id; provider_metadata = reasoning_metadata });
              current_reasoning_id := Some id;
              id
          in
          Buffer.add_string reasoning_buf text;
          Buffer.add_string current_reasoning_text text;
          Option.iter (fun value -> current_reasoning_signature := Some value) signature;
          (match reasoning_metadata with
          | Some metadata ->
            current_reasoning_provider_options := provider_options;
            current_reasoning_provider_metadata := Some metadata
          | None -> ());
          emit (Text_stream_part.Reasoning_delta { id; text; provider_metadata = reasoning_metadata });
          (* Signatures and metadata-only reasoning chunks each complete a reasoning block. *)
          if Option.is_some signature || metadata_only then close_reasoning ()
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
          (* Drive partial-output parsing off the synthetic [json] tool's args so streaming
             callers see incremental JSON on the structured-output fallback path. *)
          if String.equal tool_name Ai_provider.Mode.fallback_json_tool_name then
            on_text_accumulated (Buffer.contents buf);
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
        | Finish { finish_reason = fr; usage = u; provider_metadata = pm } ->
          close_text ();
          close_reasoning ();
          finish_reason := fr;
          usage := u;
          (match pm with
          | None -> ()
          | Some _ -> provider_metadata := pm)
        | Error { error } ->
          finish_reason := Ai_provider.Finish_reason.Error;
          emit (Text_stream_part.Error { error = Ai_provider.Provider_error.to_string error })
        | File _ | Source _ -> ())
      provider_stream
  in
  Lwt.return
    ( Buffer.contents text_buf,
      Buffer.contents reasoning_buf,
      List.rev !reasoning_content,
      List.rev !completed_tool_calls,
      !finish_reason,
      !usage,
      !provider_metadata )

let stream_text ~model ?system ?system_provider_options ?prompt ?messages ?tools
  ?(tool_choice : Ai_provider.Tool_choice.t option) ?(output : (Yojson.Basic.t, Yojson.Basic.t) Output.t option)
  ?(max_steps = 1) ?max_retries ?max_retry_delay_ms ?stop_when ?max_output_tokens ?temperature ?top_p ?top_k
  ?stop_sequences ?seed ?headers ?provider_options ?on_step_finish ?on_chunk ?on_finish ?on_abort ?transform ?telemetry
  ?(pending_tool_approvals = []) ?abort_signal () =
  (* Build initial messages *)
  let initial_messages = Prompt_builder.resolve_messages ?system ?system_provider_options ?prompt ?messages () in
  let mode = Output.mode_of_output output in
  let tools = Option.value ~default:[] tools in
  let provider_tools = Prompt_builder.tools_to_provider tools in
  (* Telemetry — precompute once; all values are [] / None when disabled *)
  let tp =
    Telemetry.precompute ~operation_id:"ai.streamText" ~model ?max_output_tokens ?temperature ?top_p ?top_k
      ?stop_sequences ?seed ?max_retries ?headers telemetry
  in
  (* Create output streams *)
  let full_stream, full_push = Lwt_stream.create () in
  let partial_output_stream, partial_output_push = Lwt_stream.create () in
  (* Promises for final values *)
  let usage_promise, usage_resolver = Lwt.wait () in
  let finish_promise, finish_resolver = Lwt.wait () in
  let steps_promise, steps_resolver = Lwt.wait () in
  let output_promise, output_resolver = Lwt.wait () in
  let provider_metadata_promise, provider_metadata_resolver = Lwt.wait () in
  (* Finish, error and abort each end the call. The first one to call [settle]
     closes the streams and settles the promises. The others then do nothing,
     and every later emit is dropped, so nothing pushes to a closed stream. *)
  let settled = ref false in
  (* Removes [abort] from the signal. Settling calls it, so a long-lived signal
     does not keep this call's closures alive. *)
  let detach_abort = ref (fun () -> ()) in
  let settle () =
    match !settled with
    | true -> false
    | false ->
      settled := true;
      !detach_abort ();
      true
  in
  let is_aborted () = Option.fold ~none:false ~some:Ai_provider.Abort_signal.is_aborted abort_signal in
  let check_abort () = Ai_provider.Abort_signal.fail_if_aborted abort_signal in
  let push_part part =
    full_push (Some part);
    Option.iter (fun f -> f part) on_chunk
  in
  (* For the parts that end the call: the streams must close even if [on_chunk]
     raises. *)
  let push_part_ignoring_errors part = try push_part part with (_ : exn) -> () in
  (* [Start] goes first even when the abort comes before the job emits it. *)
  let started = ref false in
  let emit_start ~push =
    match !started with
    | true -> ()
    | false ->
      started := true;
      push Text_stream_part.Start
  in
  (* Finished steps, newest first, for [on_abort]. *)
  let completed_steps = ref [] in
  let abort () =
    match settle () with
    | false -> ()
    | true ->
      (* Upstream also ignores an exception from onAbort. *)
      emit_start ~push:push_part_ignoring_errors;
      (try Option.iter (fun f -> f ~steps:(List.rev !completed_steps)) on_abort with (_ : exn) -> ());
      push_part_ignoring_errors (Text_stream_part.Abort { reason = None });
      full_push None;
      partial_output_push None;
      Lwt.wakeup_later_exn usage_resolver Ai_provider.Abort_signal.Aborted;
      Lwt.wakeup_later_exn finish_resolver Ai_provider.Abort_signal.Aborted;
      Lwt.wakeup_later_exn steps_resolver Ai_provider.Abort_signal.Aborted;
      Lwt.wakeup_later output_resolver None;
      Lwt.wakeup_later provider_metadata_resolver None
  in
  (* Runs right away when the signal has already fired, so the stream holds
     only [Start] and [Abort] and the job below stops before calling the model. *)
  Option.iter (fun signal -> detach_abort := Ai_provider.Abort_signal.on_abort signal abort) abort_signal;
  (* Partial output deduplication *)
  let last_partial_json = ref "" in
  let on_text_accumulated =
    match output with
    | Some o when Option.is_some o.Output.response_format ->
      fun accumulated ->
        (match o.Output.parse_partial accumulated with
        | Some json ->
          let json_str = Yojson.Basic.to_string json in
          (* Once settled, partial_output_stream is closed. *)
          (match String.equal json_str !last_partial_json || !settled with
          | true -> ()
          | false ->
            last_partial_json := json_str;
            partial_output_push (Some json))
        | None -> ())
    | _ -> fun (_ : string) -> ()
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

  let id_gen = make_id_gen () in
  Lwt.async (fun () ->
    Telemetry.maybe_span telemetry "ai.streamText" ~__FILE__ ~__LINE__ ~data:root_span_data @@ fun root_span ->
    let emit_event part = if not !settled then push_part part in
    (* Records a finished step for [on_abort], emits its [Finish_step] and runs
       [on_step_finish], in upstream's order. Fails with [Aborted] instead of
       going on once the signal has fired. *)
    let finish_step (step : Generate_text_result.step) =
      let%lwt () = check_abort () in
      completed_steps := step :: !completed_steps;
      emit_event (Text_stream_part.Finish_step { finish_reason = step.finish_reason; usage = step.usage });
      let%lwt () = check_abort () in
      Option.iter (fun f -> f step) on_step_finish;
      check_abort ()
    in
    let execute_and_emit (tc : Generate_text_result.tool_call) =
      let%lwt tr =
        Core_tool.execute_tool ?abort_signal ~tools ~tool_call_id:tc.tool_call_id ~tool_name:tc.tool_name ~args:tc.args
          ()
      in
      emit_event
        (Text_stream_part.Tool_result
           {
             tool_call_id = tr.tool_call_id;
             tool_name = tr.tool_name;
             result = tr.result;
             is_error = tr.is_error;
             provider_metadata = tr.provider_metadata;
           });
      Lwt.return tr
    in
    let execute_tool_with_telemetry ~step_num (tc : Generate_text_result.tool_call) =
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
        Core_tool.execute_tool ?abort_signal ~tools ~tool_call_id:tc.tool_call_id ~tool_name:tc.tool_name ~args:tc.args
          ()
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
      emit_event
        (Text_stream_part.Tool_result
           {
             tool_call_id = tr.tool_call_id;
             tool_name = tr.tool_name;
             result = tr.result;
             is_error = tr.is_error;
             provider_metadata = tr.provider_metadata;
           });
      Lwt.return tr
    in
    (* Everything that can raise, [on_chunk] on the [Finish] part included,
       runs before [settle], so an exception still reaches the error handler
       below with the streams open. [on_finish] runs after the streams close
       and the promises settle, so an exception from it is dropped. *)
    let finish_stream ~finish_reason ~usage ~all_steps =
      let parsed_output = Output.parse_output output all_steps in
      emit_event (Text_stream_part.Finish { finish_reason; usage });
      match settle () with
      | false -> Lwt.return_unit
      | true ->
        full_push None;
        partial_output_push None;
        (* Surface the last step's provider metadata as the call-level value,
           matching upstream's [streamText] which exposes [providerMetadata]
           from the final step on its result object. *)
        let final_provider_metadata =
          match List.rev all_steps with
          | last :: _ -> last.Generate_text_result.provider_metadata
          | [] -> None
        in
        Lwt.wakeup_later usage_resolver usage;
        Lwt.wakeup_later finish_resolver finish_reason;
        Lwt.wakeup_later steps_resolver all_steps;
        Lwt.wakeup_later output_resolver parsed_output;
        Lwt.wakeup_later provider_metadata_resolver final_provider_metadata;
        (* Telemetry: final attributes on root span *)
        (match telemetry with
        | Some t when Telemetry.enabled t ->
          Trace_core.add_data_to_span root_span
            (Telemetry.final_response_attrs
               ~text:(Generate_text_result.join_text all_steps)
               ~reasoning:(Generate_text_result.join_reasoning all_steps)
               ~finish_reason ~usage t)
        | _ -> ());
        let%lwt () =
          Telemetry.maybe_notify telemetry (fun t ->
            Telemetry.notify_on_finish t
              {
                steps = all_steps;
                total_usage = usage;
                finish_reason;
                function_id = tp.function_id_;
                metadata = tp.metadata_;
              })
        in
        Option.iter
          (fun f ->
            f
              {
                Generate_text_result.text = Generate_text_result.join_text all_steps;
                reasoning = Generate_text_result.join_reasoning all_steps;
                tool_calls = List.concat_map (fun (s : Generate_text_result.step) -> s.tool_calls) all_steps;
                tool_results = List.concat_map (fun (s : Generate_text_result.step) -> s.tool_results) all_steps;
                steps = all_steps;
                finish_reason;
                usage;
                response = { id = None; model = None; headers = []; body = `Null };
                warnings = [];
                output = parsed_output;
              })
          on_finish;
        Lwt.return_unit
    in
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
    let rec step_loop ~current_messages ~steps ~total_usage ~step_num =
      let%lwt () = check_abort () in
      if step_num > max_steps then
        finish_stream ~finish_reason:(Ai_provider.Finish_reason.Other "max_steps") ~usage:total_usage
          ~all_steps:(List.rev steps)
      else begin
        emit_event Text_stream_part.Start_step;
        let opts =
          Prompt_builder.make_call_options ~messages:current_messages ~tools:provider_tools ?tool_choice ~mode
            ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?provider_options ?headers ?abort_signal
            ()
        in
        let%lwt
          text, reasoning, reasoning_content, tool_calls, fr, step_usage, step_response_model, step_provider_metadata =
          Telemetry.maybe_span telemetry "ai.streamText.doStream" ~__FILE__ ~__LINE__ ~data:(fun () ->
            match telemetry with
            | Some t ->
              Telemetry.step_request_attrs ~operation_id:"ai.streamText.doStream" ~model_info:tp.model_info
                ~current_messages ~tools ~tool_choice ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences t
            | None -> [])
          @@ fun step_span ->
          let%lwt stream_result =
            Retry.with_retries ?abort_signal ?max_retries ?max_retry_delay_ms (fun () ->
              Ai_provider.Language_model.stream model opts)
          in
          let response_model = Option.bind stream_result.raw_response (fun response -> response.model) in
          let%lwt text, reasoning, reasoning_content, tool_calls, fr, step_usage, step_provider_metadata =
            consume_provider_stream ?abort_signal ~on_text_accumulated ~id_gen ~emit:emit_event stream_result.stream
          in
          (* Add response attributes to step span *)
          (match telemetry with
          | Some t when Telemetry.enabled t ->
            Trace_core.add_data_to_span step_span
              (Telemetry.step_response_attrs ~text ~reasoning ~tool_calls ~finish_reason:fr ~usage:step_usage
                 ?response_model t)
          | _ -> ());
          Lwt.return
            (text, reasoning, reasoning_content, tool_calls, fr, step_usage, response_model, step_provider_metadata)
        in
        (* An abort ends the provider stream early, so this step is incomplete. *)
        let%lwt () = check_abort () in
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
          let%lwt blocked_calls, executable_calls = Core_tool.evaluate_approvals ~tools tool_calls in
          let%lwt tool_results = Lwt_list.map_s (execute_tool_with_telemetry ~step_num) executable_calls in
          (* Emit approval requests only for tools that have needs_approval (not client-only tools) *)
          List.iter
            (fun (tc : Generate_text_result.tool_call) ->
              match List.assoc_opt tc.tool_name tools with
              | Some { Core_tool.needs_approval = Some _; _ } ->
                let approval_id = next_approval_id id_gen in
                emit_event
                  (Text_stream_part.Tool_approval_request
                     { approval_id; tool_call_id = tc.tool_call_id; tool_name = tc.tool_name; args = tc.args })
              | _ -> ())
            blocked_calls;
          let step : Generate_text_result.step =
            {
              text;
              reasoning;
              tool_calls;
              tool_results;
              finish_reason = fr;
              usage = step_usage;
              response_model = step_response_model;
              provider_metadata = step_provider_metadata;
            }
          in
          let%lwt () = finish_step step in
          let%lwt () =
            Telemetry.maybe_notify telemetry (fun t ->
              Telemetry.notify_on_step_finish t
                { step_number = step_num; step; function_id = tp.function_id_; metadata = tp.metadata_ })
          in
          match blocked_calls with
          | _ :: _ ->
            (* Some tools need approval — stop the stream *)
            finish_stream ~finish_reason:fr ~usage:new_total ~all_steps:(List.rev (step :: steps))
          | [] ->
            (* All tools executed — check stop conditions before continuing *)
            let%lwt stop_with_steps =
              match stop_when with
              | Some conditions ->
                let all_steps_so_far = List.rev (step :: steps) in
                let%lwt met = Stop_condition.is_met conditions ~steps:all_steps_so_far in
                Lwt.return (if met then Some all_steps_so_far else None)
              | None -> Lwt.return None
            in
            (match stop_with_steps with
            | Some all_steps_so_far -> finish_stream ~finish_reason:fr ~usage:new_total ~all_steps:all_steps_so_far
            | None ->
              let assistant_content =
                reasoning_content
                @ (if String.length text > 0 then [ Ai_provider.Content.Text { text } ] else [])
                @ List.map
                    (fun (tc : Generate_text_result.tool_call) ->
                      Ai_provider.Content.Tool_call
                        {
                          tool_call_type = "function";
                          tool_call_id = tc.tool_call_id;
                          tool_name = tc.tool_name;
                          args = Yojson.Basic.to_string tc.args;
                        })
                    tool_calls
              in
              let updated_messages =
                Prompt_builder.append_assistant_and_tool_results ~messages:current_messages ~assistant_content
                  ~tool_results
              in
              step_loop ~current_messages:updated_messages ~steps:(step :: steps) ~total_usage:new_total
                ~step_num:(step_num + 1))
        end
        else begin
          (* Final step *)
          let step : Generate_text_result.step =
            {
              text;
              reasoning;
              tool_calls;
              tool_results = [];
              finish_reason = fr;
              usage = step_usage;
              response_model = step_response_model;
              provider_metadata = step_provider_metadata;
            }
          in
          let%lwt () = finish_step step in
          let%lwt () =
            Telemetry.maybe_notify telemetry (fun t ->
              Telemetry.notify_on_step_finish t
                { step_number = step_num; step; function_id = tp.function_id_; metadata = tp.metadata_ })
          in
          finish_stream ~finish_reason:fr ~usage:new_total ~all_steps:(List.rev (step :: steps))
        end
      end
    in
    try%lwt
      emit_start ~push:emit_event;
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
                (Text_stream_part.Tool_call { tool_call_id = ta.tool_call_id; tool_name = ta.tool_name; args = ta.args }))
            approvals;
          (* Denied before approved — matches upstream emit order *)
          approvals
          |> List.filter (fun (ta : Generate_text_result.pending_tool_approval) -> not ta.approved)
          |> List.iter (fun (ta : Generate_text_result.pending_tool_approval) ->
            emit_event (Text_stream_part.Tool_output_denied { tool_call_id = ta.tool_call_id }));
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
                      provider_metadata = None;
                    }
                | true -> execute_and_emit { tool_call_id = ta.tool_call_id; tool_name = ta.tool_name; args = ta.args })
              approvals
          in
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
          let%lwt () = finish_step step in
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
          let updated_messages = initial_messages @ [ Ai_provider.Prompt.Tool { content = tool_result_parts } ] in
          Lwt.return (updated_messages, [ step ])
      in
      step_loop ~current_messages:start_messages ~steps:(List.rev initial_steps)
        ~total_usage:{ input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }
        ~step_num:(1 + List.length initial_steps)
    with exn ->
      (* After an abort, any failure is a side effect of it, such as [Aborted]
         from the provider call, so it is not reported. *)
      (match is_aborted () with
      | true -> abort ()
      | false ->
      match settle () with
      | false -> ()
      | true ->
        Trace_core.add_data_to_span root_span [ "error", `Bool true; "error.message", `String (Printexc.to_string exn) ];
        let msg = Printexc.to_string exn in
        push_part_ignoring_errors (Text_stream_part.Error { error = msg });
        full_push None;
        partial_output_push None;
        Lwt.wakeup_later_exn usage_resolver exn;
        Lwt.wakeup_later_exn finish_resolver exn;
        Lwt.wakeup_later_exn steps_resolver exn;
        Lwt.wakeup_later output_resolver None;
        Lwt.wakeup_later provider_metadata_resolver None);
      Lwt.return_unit);
  let transformed_stream =
    match transform with
    | Some f -> f full_stream
    | None -> full_stream
  in
  let consumer_full_stream, consumer_full_push = Lwt_stream.create () in
  let text_stream, text_push = Lwt_stream.create () in
  Lwt.async (fun () ->
    try%lwt
      let%lwt () =
        Lwt_stream.iter_s
          (fun part ->
            consumer_full_push (Some part);
            (match part with
            | Text_stream_part.Text_delta { text; _ } -> text_push (Some text)
            | _ -> ());
            Lwt.return_unit)
          transformed_stream
      in
      consumer_full_push None;
      text_push None;
      Lwt.return_unit
    with exn ->
      consumer_full_push (Some (Text_stream_part.Error { error = Printexc.to_string exn }));
      consumer_full_push None;
      text_push None;
      Lwt.return_unit);
  {
    Stream_text_result.text_stream;
    full_stream = consumer_full_stream;
    partial_output_stream;
    usage = usage_promise;
    finish_reason = finish_promise;
    steps = steps_promise;
    warnings = [];
    output = output_promise;
    provider_metadata = provider_metadata_promise;
  }
