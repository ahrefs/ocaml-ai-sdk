(** Convenience handler for building chat API endpoints with cohttp.

    Parses the request body as JSON messages, calls [stream_text],
    and returns an SSE response compatible with [useChat()]. *)

(** Default CORS headers for cross-origin chat endpoints.
    Allows all origins, POST/OPTIONS methods, and exposes the
    UIMessage stream protocol header. *)
val cors_headers : (string * string) list

(** Parse a v6 UIMessage request body into prompt messages.

    Expects a JSON object with a ["messages"] array where each message
    has ["role"] and ["parts"]. Supports all v6 part types:
    - ["text"]: text content
    - ["file"]: file attachments with [mediaType] and [url] or [data]
    - ["reasoning"]: assistant reasoning blocks
    - Tool invocation parts (["tool-{name}"] or ["dynamic-tool"]):
      converted to {!Ai_provider.Prompt.Tool_call} and {!Ai_provider.Prompt.Tool}
      messages based on the invocation [state]

    Returns an empty list on parse failure. Unknown part types are skipped. *)
val parse_messages_from_body : Yojson.Basic.t -> Ai_provider.Prompt.message list

(** Collect pending tool approvals from re-submitted messages.

    Scans the message history for tool invocation parts with
    [state = "approval-responded"], returning full tool call details.
    Approved tools should be executed directly before calling the LLM;
    denied tools should produce error results. *)
val collect_pending_tool_approvals : Yojson.Basic.t -> Generate_text_result.pending_tool_approval list

(** Handle an incoming chat request.

    Expects a v6 JSON body with a ["messages"] array where each message
    has ["role"] and a ["parts"] array of typed content parts.

    Returns an SSE response with UIMessage stream protocol v1 headers.
    When [cors] is [true] (the default), CORS headers are included.
    Returns [400 Bad Request] if the request body is not valid JSON.

    Note: generation parameters like [temperature], [top_p], [max_output_tokens]
    are not exposed here. Pass them via [provider_options] or call
    {!Stream_text.stream_text} directly with {!Stream_text_result.to_ui_message_sse_stream}
    and {!make_sse_response} for full control. *)
val handle_chat :
  model:Ai_provider.Language_model.t ->
  ?tools:(string * Core_tool.t) list ->
  ?max_steps:int ->
  ?stop_when:Stop_condition.t list ->
  ?system:string ->
  ?output:(Yojson.Basic.t, Yojson.Basic.t) Output.t ->
  ?send_reasoning:bool ->
  ?max_output_tokens:int ->
  ?cors:bool ->
  ?provider_options:Ai_provider.Provider_options.t ->
  ?transform:(Text_stream_part.t Lwt_stream.t -> Text_stream_part.t Lwt_stream.t) ->
  Cohttp_lwt_unix.Server.conn ->
  Cohttp.Request.t ->
  Cohttp_lwt.Body.t ->
  (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t

(** Handle a CORS preflight OPTIONS request.
    Returns [204 No Content] with CORS headers.
    Use this for the OPTIONS route matching your chat endpoint. *)
val handle_cors_preflight :
  Cohttp_lwt_unix.Server.conn -> Cohttp.Request.t -> Cohttp_lwt.Body.t -> (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t

(** Create an SSE HTTP response from a string stream.
    Adds UIMessage stream protocol headers automatically. *)
val make_sse_response :
  ?status:Cohttp.Code.status_code ->
  ?extra_headers:(string * string) list ->
  string Lwt_stream.t ->
  (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t
