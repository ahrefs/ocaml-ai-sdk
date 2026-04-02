(** HTTP client for the OpenRouter Chat Completions API. *)

type request_body

val request_body_to_json : request_body -> Melange_json.t

(** Build a typed request body for the Chat Completions API.
    Extends OpenAI-compatible parameters with OpenRouter-specific fields. *)
val make_request_body :
  model:string ->
  messages:Melange_json.t list ->
  ?temperature:float ->
  ?top_p:float ->
  ?max_tokens:int ->
  ?max_completion_tokens:int ->
  ?frequency_penalty:float ->
  ?presence_penalty:float ->
  ?stop:string list ->
  ?seed:int ->
  ?response_format:Melange_json.t ->
  ?tools:Melange_json.t list ->
  ?tool_choice:Melange_json.t ->
  ?parallel_tool_calls:bool ->
  ?reasoning_effort:string ->
  ?plugins:Melange_json.t list ->
  ?transforms:string list ->
  ?route:string ->
  ?provider:Melange_json.t ->
  ?api_keys:Melange_json.t ->
  ?include_reasoning:bool ->
  stream:bool ->
  unit ->
  request_body

(** Send a request to the Chat Completions API.
    Returns [`Json] for non-streaming, [`Stream] for streaming (raw SSE lines). *)
val chat_completions :
  config:Config.t ->
  body:request_body ->
  extra_headers:(string * string) list ->
  stream:bool ->
  [ `Json of Yojson.Basic.t | `Stream of string Lwt_stream.t ] Lwt.t
