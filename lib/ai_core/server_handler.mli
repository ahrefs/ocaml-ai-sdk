(** Convenience handler for building chat API endpoints with cohttp.

    Parses the request body as JSON messages, calls [stream_text],
    and returns an SSE response compatible with [useChat()]. *)

(** Handle an incoming chat request.

    Expects a JSON body with a ["messages"] array of
    [{"role": "user"|"assistant"|"system", "content": "..."}] objects.

    Returns an SSE response with UIMessage stream protocol v1 headers. *)
val handle_chat :
  model:Ai_provider.Language_model.t ->
  ?tools:(string * Core_tool.t) list ->
  ?max_steps:int ->
  ?system:string ->
  ?send_reasoning:bool ->
  ?provider_options:Ai_provider.Provider_options.t ->
  Cohttp_lwt_unix.Server.conn ->
  Cohttp.Request.t ->
  Cohttp_lwt.Body.t ->
  (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t

(** Create an SSE HTTP response from a string stream.
    Adds UIMessage stream protocol headers automatically. *)
val make_sse_response :
  ?status:Cohttp.Code.status_code ->
  ?extra_headers:(string * string) list ->
  string Lwt_stream.t ->
  (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t
