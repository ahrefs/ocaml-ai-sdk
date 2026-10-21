(** Non-streaming text generation with multi-step tool execution.

    Calls the provider model, executes tools if requested, feeds results
    back, and loops until the model stops or [max_steps] is reached.

    Each provider call is retried on retryable errors and transient network
    failures with exponential backoff (see {!Retry.with_retries}).

    @param max_retries Number of additional attempts per provider call
      (default 2). Set to 0 to disable retries.
    @param max_retry_delay_ms Caps backoff; a server [Retry-After] above it
      stops retries instead of sleeping. Uncapped by default.
    @param abort_signal Aborts the call. The signal goes to every provider
      request and to the retry loop. Once it has settled, no model call or
      tool starts, approved pending tools included. The returned promise
      fails with [Ai_provider.Abort_signal.Aborted] when the abort stops work
      the call still had to do, such as a provider request in flight or the
      next step. An abort that comes after the final model response, or once
      [stop_when] is met, stops nothing, and the call returns its result as
      upstream's generateText does. Tools get the signal in their
      {!Core_tool.execute_options}; a running tool that ignores it finishes
      first. *)

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
  ?telemetry:Telemetry.t ->
  ?pending_tool_approvals:Generate_text_result.pending_tool_approval list ->
  ?abort_signal:Ai_provider.Abort_signal.t ->
  unit ->
  Generate_text_result.t Lwt.t
