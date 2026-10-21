(** Non-streaming text generation with multi-step tool execution.

    Calls the provider model, executes tools if requested, feeds results
    back, and loops until the model stops or [max_steps] is reached.

    Each provider call is retried on retryable errors and transient network
    failures with exponential backoff (see {!Retry.with_retries}).

    @param max_retries Number of additional attempts per provider call
      (default 2). Set to 0 to disable retries.
    @param max_retry_delay_ms Caps backoff; a server [Retry-After] above it
      stops retries instead of sleeping. Uncapped by default.
    @param abort_signal Aborts the call. It goes to every provider request,
      to the retry loop and to each tool in its {!Core_tool.execute_options}.
      Once it has settled, no model call or tool starts, approved pending
      tools included. The call fails with [Ai_provider.Abort_signal.Aborted]
      when the abort stops work it still had to do, such as a provider
      request in flight or the next step, and fails at once even when the
      model ignores the signal and never returns. A running tool that ignores
      the signal finishes first. An abort that comes after the final model
      response, or once [stop_when] is met, stops nothing, and the call
      returns its result as upstream's generateText does. A caller that must
      not go on after an abort checks [Ai_provider.Abort_signal.is_aborted].
      A step whose model response came back is always recorded: it keeps the
      results of the tools that ran, the calls that did not run stay in its
      [tool_calls] with no result, and [on_step_finish] is not called for it.
    @param on_abort Called once when the call fails with
      [Ai_provider.Abort_signal.Aborted] because [abort_signal] fired, before
      the returned promise fails, with the steps recorded so far in order. An
      exception it raises is ignored. It is not called for [Lwt.cancel] or
      for any other failure.

    [Lwt.cancel] on the returned promise, for example from
    [Lwt_unix.with_timeout], fails it with [Lwt.Canceled] at once and
    cancels the provider request, retry sleep or tool in progress. No model
    request or tool starts after that. A cancel reports no steps, so use
    [abort_signal] when the usage must be accounted for.

    {[
      Ai_provider.Abort_signal.with_timeout 30. (fun abort_signal ->
        generate_text ~model ~prompt ~abort_signal ())
    ]}

    See docs/guides/cancellation.md. *)

val generate_text :
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
  ?on_abort:(steps:Generate_text_result.step list -> unit) ->
  ?telemetry:Telemetry.t ->
  ?pending_tool_approvals:Generate_text_result.pending_tool_approval list ->
  ?abort_signal:Ai_provider.Abort_signal.t ->
  unit ->
  Generate_text_result.t Lwt.t
