(** OpenRouter provider for the OCaml AI SDK.

    Implements the OpenRouter Chat Completions API (OpenAI-compatible)
    with extensions for plugins, BYOK routing, reasoning, and cache metrics. *)

(** Create an OpenRouter provider factory.
    [api_key] defaults to [OPENROUTER_API_KEY] env var. *)
val create :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  ?app_title:string ->
  ?app_url:string ->
  unit ->
  Ai_provider.Provider.t

(** Create a language model with explicit configuration. *)
val language_model :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  ?app_title:string ->
  ?app_url:string ->
  model:string ->
  unit ->
  Ai_provider.Language_model.t

(** Convenience: create a model using [OPENROUTER_API_KEY] env var
    and default base URL. *)
val model : string -> Ai_provider.Language_model.t

(** {1 Re-exported modules} *)

module Config = Config
module Model_catalog = Model_catalog
module Openrouter_options = Openrouter_options
module Openrouter_error = Openrouter_error
module Convert_prompt = Convert_prompt
module Convert_tools = Convert_tools
module Convert_response = Convert_response
module Convert_usage = Convert_usage
module Convert_stream = Convert_stream
module Sse = Sse
module Openrouter_api = Openrouter_api
module Openrouter_model = Openrouter_model
