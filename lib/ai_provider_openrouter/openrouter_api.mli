(** HTTP client for the OpenRouter Chat Completions API. *)

type request_body

val request_body_to_json : request_body -> Melange_json.t

(** Build a typed request body for the Chat Completions API.
    Extends OpenAI-compatible parameters with OpenRouter-specific fields. *)
val make_request_body :
  model:string ->
  messages:Melange_json.t list ->
  ?models:string list ->
  ?temperature:float ->
  ?top_p:float ->
  ?top_k:int ->
  ?max_tokens:int ->
  ?frequency_penalty:float ->
  ?presence_penalty:float ->
  ?stop:string list ->
  ?seed:int ->
  ?response_format:Melange_json.t ->
  ?tools:Melange_json.t list ->
  ?tool_choice:Melange_json.t ->
  ?parallel_tool_calls:bool ->
  ?logit_bias:Melange_json.t ->
  ?logprobs:Melange_json.t ->
  ?top_logprobs:Melange_json.t ->
  ?user:string ->
  ?include_reasoning:bool ->
  ?reasoning:Melange_json.t ->
  ?usage:Melange_json.t ->
  ?plugins:Melange_json.t list ->
  ?web_search_options:Melange_json.t ->
  ?provider:Melange_json.t ->
  ?debug:Melange_json.t ->
  ?cache_control:Melange_json.t ->
  stream:bool ->
  compatibility:Config.compatibility ->
  unit ->
  request_body

(** Merge extra_body key-value pairs into the serialized request JSON. *)
val merge_extra_body :
  Yojson.Basic.t -> (string * Yojson.Basic.t) list -> Yojson.Basic.t

(** Send a request to the Chat Completions API.
    Returns [`Json] for non-streaming, [`Stream] for streaming (raw SSE lines).
    Checks for HTTP 200 error responses (OpenRouter returns errors with 200 status). *)
val chat_completions :
  config:Config.t ->
  body:request_body ->
  extra_body:(string * Yojson.Basic.t) list ->
  extra_headers:(string * string) list ->
  stream:bool ->
  [ `Json of Yojson.Basic.t | `Stream of string Lwt_stream.t ] Lwt.t
