(** HTTP client for the Anthropic Messages API. *)

(** Build the JSON request body for the Messages API. *)
val make_request_body :
  model:string ->
  messages:Convert_prompt.anthropic_message list ->
  ?system:string ->
  ?tools:Convert_tools.anthropic_tool list ->
  ?tool_choice:Convert_tools.anthropic_tool_choice ->
  ?max_tokens:int ->
  ?temperature:float ->
  ?top_p:float ->
  ?top_k:int ->
  ?stop_sequences:string list ->
  ?thinking:Thinking.t ->
  ?stream:bool ->
  unit ->
  Yojson.Safe.t

(** Send a request to the Messages API.
    Returns [`Json] for non-streaming, [`Stream] for streaming (raw SSE lines). *)
val messages :
  config:Config.t ->
  body:Yojson.Safe.t ->
  extra_headers:(string * string) list ->
  stream:bool ->
  [ `Json of Yojson.Safe.t | `Stream of string Lwt_stream.t ] Lwt.t
