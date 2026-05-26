(** Anthropic provider for the OCaml AI SDK.

    Implements the Anthropic Messages API for Claude models. *)

(** Create an Anthropic provider factory.
    [api_key] defaults to [ANTHROPIC_API_KEY] env var. *)
val create : ?api_key:string -> ?base_url:string -> ?headers:(string * string) list -> unit -> Ai_provider.Provider.t

(** Create a language model with explicit configuration. *)
val language_model :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  model:string ->
  unit ->
  Ai_provider.Language_model.t

(** Convenience: create a model using [ANTHROPIC_API_KEY] env var
    and default base URL. *)
val model : string -> Ai_provider.Language_model.t

(** {1 Re-exported modules} *)

module Config = Config
module Model_catalog = Model_catalog
module Thinking = Thinking
module Cache_control = Cache_control
module Anthropic_options = Anthropic_options
module Cache_control_options = Cache_control_options
module Convert_prompt = Convert_prompt
module Convert_tools = Convert_tools
module Convert_response = Convert_response
module Convert_usage = Convert_usage
module Anthropic_error = Anthropic_error
module Sse = Sse
module Convert_stream = Convert_stream
module Beta_headers = Beta_headers
module Anthropic_api = Anthropic_api
module Anthropic_model = Anthropic_model
