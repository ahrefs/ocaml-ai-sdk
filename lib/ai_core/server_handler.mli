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

    Returns an empty list on parse failure. Unknown part types are skipped.
    {!parse_chat_request} reports the failure instead. *)
val parse_messages_from_body : Yojson.Basic.t -> Ai_provider.Prompt.message list

(** Collect pending tool approvals from re-submitted messages.

    Scans the message history for tool invocation parts with
    [state = "approval-responded"], returning full tool call details.
    Approved tools should be executed directly before calling the LLM;
    denied tools should produce error results. *)
val collect_pending_tool_approvals : Yojson.Basic.t -> Generate_text_result.pending_tool_approval list

(** A parsed [useChat()] request. *)
type chat_request = {
  messages : Ai_provider.Prompt.message list;  (** The conversation, as {!parse_messages_from_body} converts it. *)
  pending_tool_approvals : Generate_text_result.pending_tool_approval list;
    (** As {!collect_pending_tool_approvals} finds them. Pass them to
          {!Stream_text.stream_text}. *)
  body : Yojson.Basic.t;
    (** The whole request body, for other fields [useChat()] sends, such as
          [id], [trigger] or custom [body] fields. *)
}

(** [parse_chat_request body] parses and checks a [useChat()] request body,
    as an upstream route does with [validateUIMessages] and
    [convertToModelMessages].

    It fails when [body] is not JSON, when ["messages"] is missing, empty or
    not an array, or when a message has a role other than ["system"],
    ["user"] or ["assistant"], no ["parts"] array, or no parts at all (only
    an assistant message may have none). Unlike upstream, it does not
    require a message [id] and skips unknown part types. The error is a
    message suitable for a [400] response.

    It is the first step of {!handle_chat}. Call it directly to inspect or
    change the request before generating:

    {[
      match Ai_core.Server_handler.parse_chat_request body with
      | Error msg -> (* respond with 400 *)
      | Ok { messages; pending_tool_approvals; body = _ } ->
        let result = Ai_core.Stream_text.stream_text ~model ~messages ~pending_tool_approvals () in
        Ai_core.Server_handler.make_sse_response (Ai_core.Stream_text_result.to_ui_message_sse_stream result)
    ]} *)
val parse_chat_request : string -> (chat_request, string) result

(** [handle_chat ~model body] handles a chat request whose body is [body].

    Expects a v6 JSON body with a ["messages"] array where each message
    has ["role"] and a ["parts"] array of typed content parts.

    Returns an SSE response with UIMessage stream protocol v1 headers.
    When [cors] is [true] (the default), CORS headers are included.
    Returns [400 Bad Request] with a [{"error": message}] JSON body when
    {!parse_chat_request} rejects [body].

    Note: generation parameters like [temperature], [top_p], [max_output_tokens]
    are not exposed here. Pass them via [provider_options] or call
    {!Stream_text.stream_text} directly with {!Stream_text_result.to_ui_message_sse_stream}
    and {!make_sse_response} for full control.

    When [abort_signal] fires, the request is aborted: the SSE stream ends
    with an [abort] chunk, carrying the signal's reason when it has one, and
    [data: [DONE]], and no further model call or tool starts. See
    [?abort_signal] on {!Stream_text.stream_text}.

    @param abort_signal Aborts the request. To stop the generation when the
      client goes away, as after [useChat().stop()] or a closed tab, pass a
      signal that your web server settles when the client disconnects. The
      signal may outlive the request, such as one for server shutdown. Once
      the request's stream ends, on finish, error or abort, only the provider
      request may still hold a callback on it, until its transfer ends. That
      happens at once on abort. After an error, such as a raising telemetry
      integration, a streaming transfer may run on until its body ends. *)
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
  ?abort_signal:Ai_provider.Abort_signal.t ->
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
