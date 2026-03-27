(** OpenAI provider for the OCaml AI SDK.

    Implements the OpenAI Chat Completions API. *)

(** Create an OpenAI provider factory.
    [api_key] defaults to [OPENAI_API_KEY] env var. *)
val create :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  ?organization:string ->
  ?project:string ->
  unit ->
  Ai_provider.Provider.t

(** Create a language model with explicit configuration. *)
val language_model :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  ?organization:string ->
  ?project:string ->
  model:string ->
  unit ->
  Ai_provider.Language_model.t

(** Convenience: create a model using [OPENAI_API_KEY] env var
    and default base URL. *)
val model : string -> Ai_provider.Language_model.t

(** {1 Re-exported modules} *)

module Config = Config
module Model_catalog = Model_catalog
module Openai_options = Openai_options
module Openai_error = Openai_error
module Convert_prompt = Convert_prompt
module Convert_tools = Convert_tools
module Convert_response = Convert_response
module Convert_usage = Convert_usage
module Convert_stream = Convert_stream
module Sse = Sse
module Openai_api = Openai_api
module Openai_model = Openai_model
