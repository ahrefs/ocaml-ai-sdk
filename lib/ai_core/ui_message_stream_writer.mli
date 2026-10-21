(** Composable UIMessage stream builder.

    Provides a writer API for mixing custom chunks with LLM output
    in a single SSE response. *)

(** Opaque writer handle. Pass to {!write} and {!merge}. *)
type t

(** Write a single chunk to the output stream. Synchronous. A chunk written
    after the stream closed is dropped. *)
val write : t -> Ui_message_chunk.t -> unit

(** Merge another chunk stream into the output. Non-blocking: starts reading
    [stream] at once and pushes each chunk into the writer, so the caller can
    keep writing. While the output is open it waits for every merged stream,
    including one merged after [execute] returned, as upstream's does. A stream
    merged after the writer's last chunk is still read to its end, but its
    chunks are dropped.

    If the merged stream raises, an [Error] chunk formatted by [on_error] is
    pushed to the output. *)
val merge : t -> Ui_message_chunk.t Lwt_stream.t -> unit

(** Create a composable UIMessage chunk stream.

    The stream starts with a [Start] chunk and ends with a [Finish] chunk,
    pushed after [execute] and all merges complete. When an [Abort] chunk was
    written or merged, the writer pushes no [Finish].

    When [execute] raises, the writer pushes an [Error] chunk right away, as
    upstream's createUIMessageStream does, then waits for the merged streams
    to end before it closes the stream. Chunks those streams push later come
    after the [Error] chunk.

    When [execute] raises [Ai_provider.Abort_signal.Aborted], the stream ends
    as an abort instead: no [Error] chunk, and once the merged streams end,
    an [Abort] chunk in place of [Finish], with the reason's
    [Printexc.to_string] when it has one. Upstream sends an [error] chunk
    here. When a merged stream already sent an [Abort] chunk, the writer adds
    none. See docs/guides/cancellation.md for an [execute] that merges a
    {!Stream_text.stream_text} call.

    @param message_id Optional message ID included in the [Start] chunk.
      Use this for persistence: generate an ID server-side and pass it here
      so the frontend can associate the response with a stored message.
    @param on_error Format an exception, from [execute] or a merged stream,
      into the text of the [Error] chunk. Defaults to [Printexc.to_string],
      which sends the exception's text to the client; pass a function that
      returns a fixed message to hide it, as upstream's default does.
      When it raises, the text is ["An error occurred."], so the original
      exception is not exposed.
    @param on_finish Called after [execute] and all in-flight merges complete.
      Receives [~finish_reason:None] (the stream composer doesn't know the
      LLM's finish reason). [~is_aborted] is true if [execute] raised or if
      an [Abort] chunk was written or merged, for example from a
      {!Stream_text.stream_text} call whose abort signal fired. A chunk
      written while it runs is dropped, and the stream closes only once it
      has returned, so a reader that waits for the end also waits for it; if
      it never returns, the stream never closes. An exception it raises is
      ignored.
    @param execute User function that receives a {!t} writer. Write chunks,
      merge streams, etc. The returned promise resolving signals that the
      user's direct work is done (merged streams may still be in flight). *)
val create_ui_message_stream :
  ?message_id:string ->
  ?on_error:(exn -> string) ->
  ?on_finish:(finish_reason:string option -> is_aborted:bool -> unit Lwt.t) ->
  execute:(t -> unit Lwt.t) ->
  unit ->
  Ui_message_chunk.t Lwt_stream.t

(** Wrap a chunk stream as an HTTP SSE response.

    Pipes chunks through {!Ui_message_stream.stream_to_sse} and returns
    a response with UIMessage protocol headers. See
    {!Server_handler.response} for sending it.

    @param status Default [200].
    @param cors Include CORS headers (default: [true]). *)
val create_ui_message_stream_response :
  ?status:int ->
  ?headers:(string * string) list ->
  ?cors:bool ->
  Ui_message_chunk.t Lwt_stream.t ->
  Server_handler.response
