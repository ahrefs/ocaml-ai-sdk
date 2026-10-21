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
  Lwt.catch
    (fun () -> Abort_race.race (Some signal) (fun () -> Lwt_stream.get provider_stream))
    (function
      | Ai_provider.Abort_signal.Aborted _ when Ai_provider.Abort_signal.is_aborted signal -> Lwt.return_none
      | exn -> Lwt.fail exn)

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

(* How a [stream_text] call ends. Finish, error and abort each end it. The
   first one to happen closes the streams and settles the promises. The others
   then do nothing, and every later emit is dropped, so nothing pushes to a
   closed stream. *)
module Ending : sig
  type t

  type outputs = {
    full_stream : Text_stream_part.t Lwt_stream.t;
    partial_output_stream : Yojson.Basic.t Lwt_stream.t;
    usage : Ai_provider.Usage.t Lwt.t;
    finish_reason : Ai_provider.Finish_reason.t Lwt.t;
    steps : Generate_text_result.step list Lwt.t;
    output : Yojson.Basic.t option Lwt.t;
    provider_metadata : Ai_provider.Provider_options.t option Lwt.t;
    outcome : Stream_text_result.outcome Lwt.t;
  }

  val create :
    abort_signal:Ai_provider.Abort_signal.t option ->
    on_chunk:(Text_stream_part.t -> unit) option ->
    on_abort:(steps:Generate_text_result.step list -> unit) option ->
    t * outputs

  (** True until the call has finished, failed or been aborted. *)
  val is_running : t -> bool

  (** Pushes the part and passes it to [on_chunk] while the call runs, and
      drops it afterwards. An exception from [on_chunk] passes through. *)
  val emit : t -> Text_stream_part.t -> unit

  (** Emits [Start] unless that was done already. *)
  val emit_start : t -> unit

  (** Pushes to the partial output stream. Only call it while running. *)
  val push_partial_output : t -> Yojson.Basic.t -> unit

  (** Records the step in progress for [on_abort], once its model response
      is complete. Call it again to update the step's tool results. *)
  val set_step_in_progress : t -> Generate_text_result.step -> unit

  (** Records a finished step for [on_abort], in place of the step in
      progress. *)
  val add_step : t -> Generate_text_result.step -> unit

  (** Runs the job with {!abort} attached to the signal. It runs right away
      when the signal has already fired, so the stream holds only [Start] and
      [Abort]. The hook leaves the signal when the job ends, so a long-lived
      signal does not keep this call's closures alive. *)
  val with_abort_hook : t -> (unit -> 'a Lwt.t) -> 'a Lwt.t

  (** Emits the [Finish] part, then, if the call is still running, closes the
      streams, resolves the promises from the result and resolves [outcome]
      to [Finished]. True when this ended the call. An exception from
      [on_chunk] on the [Finish] part passes through before anything
      closes. *)
  val finish : t -> Generate_text_result.t -> bool

  (** Ends a running call with an [Error] part, fails the promises with the
      exception and resolves [outcome] to [Failed]. *)
  val fail : t -> exn -> unit

  (** Ends a running call with [Start] if it is missing, [on_abort], and an
      [Abort] part, fails the promises with [Aborted] and resolves [outcome]
      to [Aborted]. [on_abort] runs before any promise settles. *)
  val abort : t -> unit
end = struct
  type state =
    | Running
    | Finished
    | Failed
    | Aborted

  type t = {
    mutable state : state;
    mutable started : bool;
    mutable completed_steps : Generate_text_result.step list;  (** Newest first. *)
    mutable step_in_progress : Generate_text_result.step option;
    abort_signal : Ai_provider.Abort_signal.t option;
    on_chunk : (Text_stream_part.t -> unit) option;
    on_abort : (steps:Generate_text_result.step list -> unit) option;
    full_push : Text_stream_part.t option -> unit;
    partial_output_push : Yojson.Basic.t option -> unit;
    usage_resolver : Ai_provider.Usage.t Lwt.u;
    finish_reason_resolver : Ai_provider.Finish_reason.t Lwt.u;
    steps_resolver : Generate_text_result.step list Lwt.u;
    output_resolver : Yojson.Basic.t option Lwt.u;
    provider_metadata_resolver : Ai_provider.Provider_options.t option Lwt.u;
    outcome_resolver : Stream_text_result.outcome Lwt.u;
  }

  type outputs = {
    full_stream : Text_stream_part.t Lwt_stream.t;
    partial_output_stream : Yojson.Basic.t Lwt_stream.t;
    usage : Ai_provider.Usage.t Lwt.t;
    finish_reason : Ai_provider.Finish_reason.t Lwt.t;
    steps : Generate_text_result.step list Lwt.t;
    output : Yojson.Basic.t option Lwt.t;
    provider_metadata : Ai_provider.Provider_options.t option Lwt.t;
    outcome : Stream_text_result.outcome Lwt.t;
  }

  let create ~abort_signal ~on_chunk ~on_abort =
    let full_stream, full_push = Lwt_stream.create () in
    let partial_output_stream, partial_output_push = Lwt_stream.create () in
    let usage, usage_resolver = Lwt.wait () in
    let finish_reason, finish_reason_resolver = Lwt.wait () in
    let steps, steps_resolver = Lwt.wait () in
    let output, output_resolver = Lwt.wait () in
    let provider_metadata, provider_metadata_resolver = Lwt.wait () in
    let outcome, outcome_resolver = Lwt.wait () in
    ( {
        state = Running;
        started = false;
        completed_steps = [];
        step_in_progress = None;
        abort_signal;
        on_chunk;
        on_abort;
        full_push;
        partial_output_push;
        usage_resolver;
        finish_reason_resolver;
        steps_resolver;
        output_resolver;
        provider_metadata_resolver;
        outcome_resolver;
      },
      { full_stream; partial_output_stream; usage; finish_reason; steps; output; provider_metadata; outcome } )

  let is_running t =
    match t.state with
    | Running -> true
    | Finished | Failed | Aborted -> false

  let push t part =
    t.full_push (Some part);
    Option.iter (fun f -> f part) t.on_chunk

  (* For the parts that end the call: the streams must close even if
     [on_chunk] raises. *)
  let push_ignoring_errors t part = try push t part with (_ : exn) -> ()

  let emit t part = if is_running t then push t part

  (* [Start] goes first even when the abort comes before the job emits it. *)
  let start t ~push =
    match t.started with
    | true -> ()
    | false ->
      t.started <- true;
      push Text_stream_part.Start

  let emit_start t = start t ~push:(emit t)
  let push_partial_output t json = t.partial_output_push (Some json)
  let set_step_in_progress t step = t.step_in_progress <- Some step

  let add_step t step =
    t.completed_steps <- step :: t.completed_steps;
    t.step_in_progress <- None

  (* The steps for [on_abort], in order, the step in progress last. *)
  let steps_so_far t = List.rev_append t.completed_steps (Option.to_list t.step_in_progress)

  let close t =
    t.full_push None;
    t.partial_output_push None

  (* [outcome] settles last, after the other promises. *)
  let reject t exn ~outcome =
    Lwt.wakeup_later_exn t.usage_resolver exn;
    Lwt.wakeup_later_exn t.finish_reason_resolver exn;
    Lwt.wakeup_later_exn t.steps_resolver exn;
    Lwt.wakeup_later_exn t.output_resolver exn;
    Lwt.wakeup_later_exn t.provider_metadata_resolver exn;
    Lwt.wakeup_later t.outcome_resolver outcome

  let finish t (result : Generate_text_result.t) =
    emit t (Text_stream_part.Finish { finish_reason = result.finish_reason; usage = result.usage });
    match t.state with
    | Finished | Failed | Aborted -> false
    | Running ->
      t.state <- Finished;
      close t;
      (* Surface the last step's provider metadata as the call-level value,
         matching upstream's [streamText] which exposes [providerMetadata]
         from the final step on its result object. *)
      let provider_metadata =
        match List.rev result.steps with
        | last :: _ -> last.Generate_text_result.provider_metadata
        | [] -> None
      in
      Lwt.wakeup_later t.usage_resolver result.usage;
      Lwt.wakeup_later t.finish_reason_resolver result.finish_reason;
      Lwt.wakeup_later t.steps_resolver result.steps;
      Lwt.wakeup_later t.output_resolver result.output;
      Lwt.wakeup_later t.provider_metadata_resolver provider_metadata;
      Lwt.wakeup_later t.outcome_resolver (Stream_text_result.Finished result);
      true

  let fail t exn =
    match t.state with
    | Finished | Failed | Aborted -> ()
    | Running ->
      t.state <- Failed;
      push_ignoring_errors t (Text_stream_part.Error { error = Printexc.to_string exn });
      close t;
      reject t exn ~outcome:(Stream_text_result.Failed exn)

  let abort t =
    match t.state with
    | Finished | Failed | Aborted -> ()
    | Running ->
      t.state <- Aborted;
      let reason = Option.bind t.abort_signal Ai_provider.Abort_signal.reason in
      let steps = steps_so_far t in
      start t ~push:(push_ignoring_errors t);
      (* Upstream also ignores an exception from onAbort. *)
      (try Option.iter (fun f -> f ~steps) t.on_abort with (_ : exn) -> ());
      (* As upstream's onChunk, [on_chunk] never sees the [Abort] part. *)
      t.full_push (Some (Text_stream_part.Abort { reason = Option.map Printexc.to_string reason }));
      close t;
      reject t (Ai_provider.Abort_signal.Aborted { reason }) ~outcome:(Stream_text_result.Aborted { steps; reason })

  let with_abort_hook t job =
    match t.abort_signal with
    | None -> job ()
    | Some signal -> Ai_provider.Abort_signal.with_on_abort signal (fun () -> abort t) job
end

let stream_text ~model ?system ?system_provider_options ?prompt ?messages ?tools
  ?(tool_choice : Ai_provider.Tool_choice.t option) ?(output : (Yojson.Basic.t, Yojson.Basic.t) Output.t option)
  ?(max_steps = 1) ?max_retries ?max_retry_delay_ms ?stop_when ?max_output_tokens ?temperature ?top_p ?top_k
  ?stop_sequences ?seed ?headers ?provider_options ?on_step_finish ?on_chunk ?on_finish ?on_abort ?transform ?telemetry
  ?(pending_tool_approvals = []) ?abort_signal () =
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
    Telemetry.precompute ~operation_id:"ai.streamText" ~model ?max_output_tokens ?temperature ?top_p ?top_k
      ?stop_sequences ?seed ?max_retries ?headers telemetry
  in
  let ending, outputs = Ending.create ~abort_signal ~on_chunk ~on_abort in
  let is_aborted () = Option.fold ~none:false ~some:Ai_provider.Abort_signal.is_aborted abort_signal in
  let guard f = Ai_provider.Abort_signal.guard abort_signal f in
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
          (match String.equal json_str !last_partial_json || not (Ending.is_running ending) with
          | true -> ()
          | false ->
            last_partial_json := json_str;
            Ending.push_partial_output ending json)
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
    Ending.with_abort_hook ending @@ fun () ->
    Telemetry.maybe_span telemetry "ai.streamText" ~__FILE__ ~__LINE__ ~data:root_span_data @@ fun root_span ->
    let emit_event part = Ending.emit ending part in
    (* Records a finished step for [on_abort], emits its [Finish_step] and runs
       [on_step_finish], in upstream's order. Fails with [Aborted] instead of
       going on once the signal has fired. *)
    let finish_step (step : Generate_text_result.step) =
      let%lwt () =
        guard (fun () ->
          Ending.add_step ending step;
          emit_event (Text_stream_part.Finish_step { finish_reason = step.finish_reason; usage = step.usage });
          Lwt.return_unit)
      in
      guard (fun () ->
        Option.iter (fun f -> f step) on_step_finish;
        Lwt.return_unit)
    in
    let execute_and_emit ~messages (tc : Generate_text_result.tool_call) =
      let%lwt tr =
        Core_tool.execute_tool ?abort_signal ~tools ~messages ~tool_call_id:tc.tool_call_id ~tool_name:tc.tool_name
          ~args:tc.args ()
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
    let execute_tool_with_telemetry ~step_num ~messages (tc : Generate_text_result.tool_call) =
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
        Core_tool.execute_tool ?abort_signal ~tools ~messages ~tool_call_id:tc.tool_call_id ~tool_name:tc.tool_name
          ~args:tc.args ()
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
    (* Runs a step's tools one after another. [step_with] builds the step from
       the results so far, and that step stays the step in progress for
       [on_abort] as each result arrives. *)
    let run_tool_batch ~step_with run calls =
      let results = ref [] in
      Ending.set_step_in_progress ending (step_with []);
      Tool_batch.run ~abort_signal
        (fun call ->
          let%lwt result = run call in
          results := result :: !results;
          Ending.set_step_in_progress ending (step_with (List.rev !results));
          Lwt.return result)
        calls
    in
    (* Everything that can raise, [on_chunk] on the [Finish] part included,
       runs before [Ending.finish] settles, so an exception still reaches the
       error handler below with the streams open. [on_finish] runs after the
       streams close and the promises settle, so an exception from it is
       dropped. *)
    let finish_stream ~finish_reason ~usage ~all_steps =
      let result = Final_result.make ~finish_reason ~usage ~output:(Output.parse_output output all_steps) all_steps in
      match Ending.finish ending result with
      | false -> Lwt.return_unit
      | true ->
        (* Telemetry: final attributes on root span *)
        (match telemetry with
        | Some t when Telemetry.enabled t ->
          Trace_core.add_data_to_span root_span
            (Telemetry.final_response_attrs ~text:result.text ~reasoning:result.reasoning ~finish_reason ~usage t)
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
        Option.iter (fun f -> f result) on_finish;
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
    let rec step_loop ~step_messages ~steps ~total_usage ~step_num =
      if step_num > max_steps then
        finish_stream ~finish_reason:(Ai_provider.Finish_reason.Other "max_steps") ~usage:total_usage
          ~all_steps:(List.rev steps)
      else begin
        (* No step starts once the signal has fired, and an abort ends the
           provider stream early, so the guard drops the incomplete step. *)
        let%lwt
          text, reasoning, reasoning_content, tool_calls, fr, step_usage, step_response_model, step_provider_metadata =
          guard @@ fun () ->
          emit_event Text_stream_part.Start_step;
          let current_messages = with_system step_messages in
          let opts =
            Prompt_builder.make_call_options ~messages:current_messages ~tools:provider_tools ?tool_choice ~mode
              ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?provider_options ?headers
              ?abort_signal ()
          in
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
        let step_with tool_results : Generate_text_result.step =
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
        (* The response is complete, so an abort from here on reports the step. *)
        Ending.set_step_in_progress ending (step_with []);
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
          let%lwt batch =
            run_tool_batch ~step_with (execute_tool_with_telemetry ~step_num ~messages:step_messages) executable_calls
          in
          let tool_results = Tool_batch.results batch in
          let%lwt () = Tool_batch.fail_if_aborted ~abort_signal batch in
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
          let step = step_with tool_results in
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
                Prompt_builder.append_assistant_and_tool_results ~messages:step_messages ~assistant_content
                  ~tool_results
              in
              step_loop ~step_messages:updated_messages ~steps:(step :: steps) ~total_usage:new_total
                ~step_num:(step_num + 1))
        end
        else begin
          (* Final step *)
          let step = step_with [] in
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
      Ending.emit_start ending;
      (* Execute pending tool approvals before starting the LLM step loop *)
      let%lwt start_messages, initial_steps =
        match pending_tool_approvals with
        | [] -> Lwt.return (request_messages, [])
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
          let tool_calls =
            List.map
              (fun (ta : Generate_text_result.pending_tool_approval) ->
                { Generate_text_result.tool_call_id = ta.tool_call_id; tool_name = ta.tool_name; args = ta.args })
              approvals
          in
          let step_with tool_results : Generate_text_result.step =
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
          let%lwt batch =
            run_tool_batch ~step_with
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
                  execute_and_emit ~messages:request_messages
                    { tool_call_id = ta.tool_call_id; tool_name = ta.tool_name; args = ta.args })
              approvals
          in
          let tool_results = Tool_batch.results batch in
          let%lwt () = Tool_batch.fail_if_aborted ~abort_signal batch in
          let step = step_with tool_results in
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
          let updated_messages = request_messages @ [ Ai_provider.Prompt.Tool { content = tool_result_parts } ] in
          Lwt.return (updated_messages, [ step ])
      in
      step_loop ~step_messages:start_messages ~steps:(List.rev initial_steps)
        ~total_usage:{ input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }
        ~step_num:(1 + List.length initial_steps)
    with exn ->
      (* After an abort, any failure is a side effect of it, such as [Aborted]
         from the provider call, so it is not reported. *)
      (match is_aborted () with
      | true -> Ending.abort ending
      | false ->
        if Ending.is_running ending then
          Trace_core.add_data_to_span root_span
            [ "error", `Bool true; "error.message", `String (Printexc.to_string exn) ];
        Ending.fail ending exn);
      Lwt.return_unit);
  let transformed_stream =
    match transform with
    | Some f -> f outputs.full_stream
    | None -> outputs.full_stream
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
    partial_output_stream = outputs.partial_output_stream;
    usage = outputs.usage;
    finish_reason = outputs.finish_reason;
    steps = outputs.steps;
    warnings = [];
    output = outputs.output;
    provider_metadata = outputs.provider_metadata;
    outcome = outputs.outcome;
  }
