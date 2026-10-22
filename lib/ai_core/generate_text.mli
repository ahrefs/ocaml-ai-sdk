(** Non-streaming text generation with multi-step tool execution.

    Calls the provider model, executes tools if requested, feeds results
    back, and loops until the model stops or [max_steps] is reached.

    Each provider call is retried on retryable errors and transient network
    failures with exponential backoff (see {!Retry.with_retries}).

    @param max_retries Number of additional attempts per provider call
      (default 2). Set to 0 to disable retries.
    @param max_retry_delay_ms Caps backoff; a server [Retry-After] above it
      stops retries instead of sleeping. Uncapped by default.
    @param abort_signal Aborts the call. Each provider request, the retry
      loop and each tool get it, the tools in their
      {!Core_tool.execute_options}. Once it has fired, no model call, tool or
      step starts, approved pending tools included, and the call fails with
      [Ai_provider.Abort_signal.Aborted] at once, even when the model or a
      tool ignores the signal. Any failure after the signal fired, such as a
      model's own [Lwt.Canceled], fails the call with that [Aborted] and
      calls [on_abort]. An abort that comes after the final model
      response, or once [stop_when] is met, stops nothing, and the call
      returns its result. A tool's result counts only if its [execute]
      returned before the signal fired, even when the abort comes while the
      result is being reported. A step whose model response came back is
      recorded with those results, and its other calls stay in [tool_calls]
      with no result. [on_step_finish] is not called for a step whose tools
      an abort stopped.
    @param on_abort Called once when the call fails with
      [Ai_provider.Abort_signal.Aborted] because [abort_signal] fired, before
      the returned promise fails, with the steps recorded so far in order.
      They start with the steps [on_step_finish] got, and any step after
      those is one it did not get, such as the step whose tools the abort
      stopped. Inside [on_abort], [Ai_provider.Abort_signal.reason] of the
      signal is the reason the call fails with. An exception it raises is
      ignored. It is not called for any other failure, nor once the call has
      been cancelled.

    [Lwt.cancel] on the returned promise, for example from
    [Lwt_unix.with_timeout], fails it with [Lwt.Canceled] at once and
    cancels the provider request, retry sleep or tool in progress. No model
    request, tool or step starts after that, and a cancel reports no steps.

    {[
      Ai_provider.Abort_signal.with_timeout 30. (fun abort_signal ->
        generate_text ~model ~prompt ~abort_signal ())
    ]}

    The {{:https://github.com/ahrefs/ocaml-ai-sdk/blob/main/docs/guides/cancellation.md} cancellation guide} covers usage accounting and how a signal differs from
    [Lwt.cancel]. *)

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
