(** Building blocks for chat API endpoints that serve [useChat()].

    {!handle_chat} parses the request body as JSON messages, calls
    [stream_text], and returns an SSE response. Responses are plain
    {!response} values that work with any web server. With cohttp, for
    example:

    {[
      let respond (r : Ai_core.Server_handler.response) =
        Cohttp_lwt_unix.Server.respond ~status:(Cohttp.Code.status_of_code r.status)
          ~headers:(Cohttp.Header.of_list r.headers) ~body:(Cohttp_lwt.Body.of_stream r.body) ()

      let callback _conn _req body =
        let%lwt body = Cohttp_lwt.Body.to_string body in
        respond (Ai_core.Server_handler.handle_chat ~model body)
    ]} *)

(** An HTTP response for the web server to send.

    [body] yields the response body in chunks. Send each chunk as it arrives:
    for an SSE response, each chunk is one event, and the client renders it
    only once it is sent. The stream can be read once. *)
type response = {
  status : int;
  headers : (string * string) list;
  body : string Lwt_stream.t;
}

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

(** [handle_chat ~model body] handles a chat request whose body is [body].

    Expects a v6 JSON body with a ["messages"] array where each message
    has ["role"] and a ["parts"] array of typed content parts.

    Returns an SSE response with UIMessage stream protocol v1 headers.
    When [cors] is [true] (the default), CORS headers are included.
    Returns [400 Bad Request] with a JSON error body if [body] is not valid
    JSON.

    Note: generation parameters like [temperature], [top_p], [max_output_tokens]
    are not exposed here. Pass them via [provider_options] or call
    {!Stream_text.stream_text} directly with {!Stream_text_result.to_ui_message_sse_stream}
    and {!make_sse_response} for full control. *)
val handle_chat :
  model:Ai_provider.Language_model.t ->
  ?tools:(string * Core_tool.t) list ->
  ?max_steps:int ->
  ?max_retries:int ->
  ?max_retry_delay_ms:int ->
  ?stop_when:Stop_condition.t list ->
  ?system:string ->
  ?system_provider_options:Ai_provider.Provider_options.t ->
  ?output:(Yojson.Basic.t, Yojson.Basic.t) Output.t ->
  ?send_reasoning:bool ->
  ?max_output_tokens:int ->
  ?cors:bool ->
  ?provider_options:Ai_provider.Provider_options.t ->
  ?transform:(Text_stream_part.t Lwt_stream.t -> Text_stream_part.t Lwt_stream.t) ->
  ?telemetry:Telemetry.t ->
  string ->
  response
(** [system_provider_options] attaches per-message provider options to the
    [?system] prompt. Use with
    {!Ai_provider_anthropic.Cache_control_options.with_cache_control} to mark
    the system prompt as a cache breakpoint. *)

(** The response to a CORS preflight OPTIONS request: [204 No Content] with
    {!cors_headers} and an empty body. Use it for the OPTIONS route matching
    your chat endpoint. *)
val handle_cors_preflight : unit -> response

(** [make_sse_response sse] is a response whose body is the SSE stream [sse],
    with the UIMessage stream protocol headers followed by [extra_headers].

    @param status Default [200]. *)
val make_sse_response : ?status:int -> ?extra_headers:(string * string) list -> string Lwt_stream.t -> response
