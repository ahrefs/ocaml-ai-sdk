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

let generate_text ~model ?system ?prompt ?messages ?tools ?(tool_choice : Ai_provider.Tool_choice.t option) ?output
  ?(max_steps = 1) ?max_retries ?stop_when ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?headers
  ?provider_options ?on_step_finish ?telemetry ?(pending_tool_approvals = []) () =
  (* Build initial messages *)
  let initial_messages = Prompt_builder.resolve_messages ?system ?prompt ?messages () in
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
          output = None;
        }
    end
    else begin
      let opts =
        Prompt_builder.make_call_options ~messages:current_messages ~tools:provider_tools ?tool_choice ~mode
          ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?provider_options ?headers ()
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
        let%lwt result = Retry.with_retries ?max_retries (fun () -> Ai_provider.Language_model.generate model opts) in
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
        let%lwt blocked_calls, executable_calls = Core_tool.evaluate_approvals ~tools tool_calls in
        let%lwt tool_results =
          Lwt_list.map_s
            (fun (tc : Generate_text_result.tool_call) ->
              Telemetry.maybe_span telemetry "ai.toolCall" ~__FILE__ ~__LINE__ ~data:(fun () ->
                match telemetry with
                | Some t ->
                  Telemetry.tool_call_span_data ~model_info:tp.model_info ~tool_name:tc.tool_name
                    ~tool_call_id:tc.tool_call_id ~args:tc.args t
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
                Core_tool.execute_tool ~tools ~tool_call_id:tc.tool_call_id ~tool_name:tc.tool_name ~args:tc.args
              in
              let duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
              let%lwt () =
                Telemetry.maybe_notify telemetry (fun t ->
                  let outcome =
                    if tr.is_error then Telemetry.Error (Yojson.Basic.to_string tr.result)
                    else Telemetry.Success tr.result
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
              Lwt.return tr)
            executable_calls
        in
        let step : Generate_text_result.step =
          { text; reasoning; tool_calls; tool_results; finish_reason = result.finish_reason; usage = result.usage }
        in
        Option.iter (fun f -> f step) on_step_finish;
        let%lwt () =
          Telemetry.maybe_notify telemetry (fun t ->
            Telemetry.notify_on_step_finish t
              { step_number = step_num; step; function_id = tp.function_id_; metadata = tp.metadata_ })
        in
        match blocked_calls with
        | _ :: _ ->
          (* Some tools need approval — stop the loop after executing ready tools *)
          let all_steps = List.rev (step :: steps) in
          let parsed_output = Output.parse_output output all_steps in
          Lwt.return
            {
              Generate_text_result.text = Generate_text_result.join_text all_steps;
              reasoning = Generate_text_result.join_reasoning all_steps;
              tool_calls = List.rev (List.rev_append tool_calls all_tool_calls);
              tool_results = List.rev (List.rev_append tool_results all_tool_results);
              steps = all_steps;
              finish_reason = result.finish_reason;
              usage = new_usage;
              response = result.response;
              warnings = result.warnings;
              output = parsed_output;
            }
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
              Prompt_builder.append_assistant_and_tool_results ~messages:current_messages
                ~assistant_content:result.content ~tool_results
            in
            loop ~current_messages:updated_messages ~steps:(step :: steps) ~total_usage:new_usage
              ~all_tool_calls:(List.rev_append tool_calls all_tool_calls)
              ~all_tool_results:(List.rev_append tool_results all_tool_results)
              ~step_num:(step_num + 1)
          | Some all_steps_so_far ->
            let parsed_output = Output.parse_output output all_steps_so_far in
            Lwt.return
              Generate_text_result.
                {
                  text = join_text all_steps_so_far;
                  reasoning = join_reasoning all_steps_so_far;
                  tool_calls = List.rev (List.rev_append tool_calls all_tool_calls);
                  tool_results = List.rev (List.rev_append tool_results all_tool_results);
                  steps = all_steps_so_far;
                  finish_reason = result.finish_reason;
                  usage = new_usage;
                  response = result.response;
                  warnings = result.warnings;
                  output = parsed_output;
                })
      end
      else begin
        (* Final step - no more tool calls *)
        let step : Generate_text_result.step =
          { text; reasoning; tool_calls; tool_results = []; finish_reason = result.finish_reason; usage = result.usage }
        in
        Option.iter (fun f -> f step) on_step_finish;
        let%lwt () =
          Telemetry.maybe_notify telemetry (fun t ->
            Telemetry.notify_on_step_finish t
              { step_number = step_num; step; function_id = tp.function_id_; metadata = tp.metadata_ })
        in
        let all_steps = List.rev (step :: steps) in
        let parsed_output = Output.parse_output output all_steps in
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
            output = parsed_output;
          }
      end
    end
  in
  (* Execute pending tool approvals before the LLM step loop *)
  let%lwt start_messages, initial_steps, initial_tool_calls, initial_tool_results =
    match pending_tool_approvals with
    | [] -> Lwt.return (initial_messages, [], [], [])
    | approvals ->
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
            | true -> Core_tool.execute_tool ~tools ~tool_call_id:ta.tool_call_id ~tool_name:ta.tool_name ~args:ta.args)
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
        }
      in
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
      let updated_messages = initial_messages @ [ Ai_provider.Prompt.Tool { content = tool_result_parts } ] in
      Lwt.return (updated_messages, [ step ], tool_calls, tool_results)
  in
  let%lwt final_result =
    loop ~current_messages:start_messages ~steps:(List.rev initial_steps)
      ~total_usage:{ input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }
      ~all_tool_calls:initial_tool_calls ~all_tool_results:initial_tool_results
      ~step_num:(1 + List.length initial_steps)
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
