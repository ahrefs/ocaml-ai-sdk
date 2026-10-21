(** The result of a call that finished. [generate_text] and [stream_text]
    both build it here, so the two build it the same way. Internal to
    [ai_core]: [Ai_core] does not export this module. *)

(** [make ~finish_reason ~usage ~output steps] joins the text and reasoning
    of [steps] and lists their tool calls and tool results in order.
    [response] defaults to an empty one and [warnings] to none. *)
val make :
  ?response:Ai_provider.Generate_result.response_info ->
  ?warnings:Ai_provider.Warning.t list ->
  finish_reason:Ai_provider.Finish_reason.t ->
  usage:Ai_provider.Usage.t ->
  output:Yojson.Basic.t option ->
  Generate_text_result.step list ->
  Generate_text_result.t
