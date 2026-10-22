(** Streaming text generation with multi-step tool execution.

    Returns synchronously with streams that are filled asynchronously.
    Tool calls are executed between steps, with the model called again
    to continue generation.

    Each provider call is retried on retryable errors and transient network
    failures with exponential backoff (see {!Retry.with_retries}).

    @param max_retries Number of additional attempts per provider call
      (default 2). Set to 0 to disable retries.
    @param max_retry_delay_ms Caps backoff; a server [Retry-After] above it
      stops retries instead of sleeping. Uncapped by default.
    @param abort_signal Aborts the call. Each provider request, the retry
      loop and each tool get it, the tools in their
      {!Core_tool.execute_options}. When it fires, [full_stream] gets an
      [Abort] part and closes at once, with nothing after it, and
      [text_stream] closes too. [usage], [finish_reason], [steps], [output]
      and [provider_metadata] fail with [Ai_provider.Abort_signal.Aborted],
      and [outcome] resolves to [Aborted] with the steps recorded so far. No
      model call, tool or step starts after the abort, no further provider
      part is processed, even from a model that ignores the signal, and
      [on_step_finish] and [on_finish] are not called. A tool's result counts
      only if its [execute] returned before the signal fired, even when the
      abort comes from [on_chunk] on its [Tool_result] part. A signal that has
      already fired gives a stream holding [Start] then [Abort] without
      calling the model. [stream_text] returns no promise for [Lwt.cancel] to
      act on, so the signal is the only way to stop it.
    @param on_chunk Called with each part, except [Abort], right after it is
      pushed to [full_stream], including the [Error] part of a failed call.
      An exception it raises ends the call like any other error: an [Error]
      part follows and the result promises fail with it. Exceptions it
      raises on the [Error] part are ignored. The call has already ended when
      it gets the [Finish] part, so an exception or an abort from it then
      does nothing.
    @param on_step_finish Called after the step's [Finish_step] part is
      pushed, as upstream does.
    @param on_finish Called after the streams close and the result promises
      resolve. An exception it raises is ignored.
    @param on_abort Called once when [abort_signal] fires, before the
      [Abort] part and before the result promises settle, with the steps
      recorded so far in order. A step is recorded once its model response
      is complete, with the results its tools returned before the abort. An
      exception it raises is ignored.

    The work given to {!Ai_provider.Abort_signal.with_timeout} must last until
    the stream ends, since its timer stops once that promise settles:

    {[
      Ai_provider.Abort_signal.with_timeout 30. (fun abort_signal ->
        let result = stream_text ~model ~prompt ~abort_signal () in
        let%lwt () = Lwt_stream.iter_s Lwt_io.print result.text_stream in
        result.outcome)
    ]}

    The {{:https://github.com/ahrefs/ocaml-ai-sdk/blob/main/docs/guides/cancellation.md} cancellation guide} covers usage accounting and how a signal differs from
    [Lwt.cancel]. *)

val stream_text :
  model:Ai_provider.Language_model.t ->
  ?system:string ->
  ?system_provider_options:Ai_provider.Provider_options.t ->
  ?prompt:string ->
  ?messages:Ai_provider.Prompt.message list ->
  ?tools:(string * Core_tool.t) list ->
  ?tool_choice:Ai_provider.Tool_choice.t ->
  ?output:(Yojson.Basic.t, Yojson.Basic.t) Output.t ->
  ?max_steps:int ->
  ?max_retries:int ->
  ?max_retry_delay_ms:int ->
  ?stop_when:Stop_condition.t list ->
  ?max_output_tokens:int ->
  ?temperature:float ->
  ?top_p:float ->
  ?top_k:int ->
  ?stop_sequences:string list ->
  ?seed:int ->
  ?headers:(string * string) list ->
  ?provider_options:Ai_provider.Provider_options.t ->
  ?on_step_finish:(Generate_text_result.step -> unit) ->
  ?on_chunk:(Text_stream_part.t -> unit) ->
  ?on_finish:(Generate_text_result.t -> unit) ->
  ?on_abort:(steps:Generate_text_result.step list -> unit) ->
  ?transform:(Text_stream_part.t Lwt_stream.t -> Text_stream_part.t Lwt_stream.t) ->
  ?telemetry:Telemetry.t ->
  ?pending_tool_approvals:Generate_text_result.pending_tool_approval list ->
  ?abort_signal:Ai_provider.Abort_signal.t ->
  unit ->
  Stream_text_result.t
