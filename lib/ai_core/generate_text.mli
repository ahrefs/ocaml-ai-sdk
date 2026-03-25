(** Non-streaming text generation with multi-step tool execution.

    Calls the provider model, executes tools if requested, feeds results
    back, and loops until the model stops or [max_steps] is reached. *)

val generate_text :
  model:Ai_provider.Language_model.t ->
  ?system:string ->
  ?prompt:string ->
  ?messages:Ai_provider.Prompt.message list ->
  ?tools:(string * Core_tool.t) list ->
  ?tool_choice:Ai_provider.Tool_choice.t ->
  ?output:(Yojson.Basic.t, Yojson.Basic.t) Output.t ->
  ?max_steps:int ->
  ?max_output_tokens:int ->
  ?temperature:float ->
  ?top_p:float ->
  ?top_k:int ->
  ?stop_sequences:string list ->
  ?seed:int ->
  ?headers:(string * string) list ->
  ?provider_options:Ai_provider.Provider_options.t ->
  ?on_step_finish:(Generate_text_result.step -> unit) ->
  unit ->
  Generate_text_result.t Lwt.t
