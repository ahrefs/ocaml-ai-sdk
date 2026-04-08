(** Streaming text generation with multi-step tool execution.

    Returns synchronously with streams that are filled asynchronously.
    Tool calls are executed between steps, with the model called again
    to continue generation. *)

val stream_text :
  model:Ai_provider.Language_model.t ->
  ?system:string ->
  ?prompt:string ->
  ?messages:Ai_provider.Prompt.message list ->
  ?tools:(string * Core_tool.t) list ->
  ?tool_choice:Ai_provider.Tool_choice.t ->
  ?output:(Yojson.Basic.t, Yojson.Basic.t) Output.t ->
  ?max_steps:int ->
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
  ?pending_tool_approvals:Generate_text_result.pending_tool_approval list ->
  unit ->
  Stream_text_result.t
