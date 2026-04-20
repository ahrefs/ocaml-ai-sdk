(** HTTP client for the Anthropic Messages API. *)

type output_format = {
  type_ : string;
  schema : Melange_json.t;
}

type output_config = { format : output_format }

type request_body

val request_body_to_json : request_body -> Melange_json.t

(** Build a typed request body for the Messages API. *)
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
  ?output_config:output_config ->
  ?stream:bool ->
  unit ->
  request_body

(** Send a request to the Messages API.
    Returns [`Json] for non-streaming, [`Stream] for streaming (raw SSE lines). *)
val messages :
  config:Config.t ->
  body:request_body ->
  extra_headers:(string * string) list ->
  stream:bool ->
  [ `Json of Yojson.Basic.t | `Stream of string Lwt_stream.t ] Lwt.t
