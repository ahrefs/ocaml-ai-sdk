(** HTTP client for the OpenAI Chat Completions API. *)

type request_body

val request_body_to_json : request_body -> Jsonkit.t

(** Build a typed request body for the Chat Completions API. *)
val make_request_body :
  model:string ->
  messages:Jsonkit.t list ->
  ?temperature:float ->
  ?top_p:float ->
  ?max_tokens:int ->
  ?max_completion_tokens:int ->
  ?frequency_penalty:float ->
  ?presence_penalty:float ->
  ?stop:string list ->
  ?seed:int ->
  ?response_format:Jsonkit.t ->
  ?tools:Jsonkit.t list ->
  ?tool_choice:Jsonkit.t ->
  ?parallel_tool_calls:bool ->
  ?logit_bias:Jsonkit.t ->
  ?logprobs:bool ->
  ?top_logprobs:int ->
  ?user:string ->
  ?reasoning_effort:string ->
  ?store:bool ->
  ?metadata:Jsonkit.t ->
  ?prediction:Jsonkit.t ->
  ?service_tier:string ->
  stream:bool ->
  unit ->
  request_body

(** Send a request to the Chat Completions API.
    Returns [`Json] for non-streaming, [`Stream] for streaming (raw SSE lines).
    Fails with [Ai_provider.Abort_signal.Aborted] once [abort_signal] settles.
    The models pass [Call_options.abort_signal]. *)
val chat_completions :
  ?abort_signal:Ai_provider.Abort_signal.t ->
  config:Config.t ->
  body:request_body ->
  extra_headers:(string * string) list ->
  stream:bool ->
  unit ->
  [ `Json of Jsonkit.t | `Stream of string Lwt_stream.t ] Lwt.t
