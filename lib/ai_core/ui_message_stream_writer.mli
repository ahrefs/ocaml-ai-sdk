(** Composable UIMessage stream builder.

    Provides a writer API for mixing custom chunks with LLM output
    in a single SSE response. *)

(** Opaque writer handle. Pass to {!write} and {!merge}. *)
type t

(** Write a single chunk to the output stream. Synchronous. *)
val write : t -> Ui_message_chunk.t -> unit

(** Merge another chunk stream into the output. Non-blocking: spawns a
    background task that consumes [stream] and pushes each chunk into the
    writer. Returns immediately so the caller can continue writing.

    If the merged stream raises, an [Error] chunk is pushed to the output.

    {b Why Lwt.async is safe here:}
    - The push target is an unbounded [Lwt_stream] — pushes never block or fail.
    - [try%lwt] wraps the consumer so exceptions become [Error] chunks
      instead of hitting [Lwt.async_exception_hook].
    - An in-flight counter ensures the output stream stays open until all
      merge tasks complete — no writes to a closed stream. *)
val merge : t -> Ui_message_chunk.t Lwt_stream.t -> unit

(** Create a composable UIMessage chunk stream.

    @param message_id Optional message ID included in the [Start] chunk.
      Use this for persistence: generate an ID server-side and pass it here
      so the frontend can associate the response with a stored message.
    @param on_error Format an exception into an error string for the [Error]
      chunk. Defaults to [Printexc.to_string].
    @param on_finish Called after [execute] and all in-flight merges complete.
      Receives [~finish_reason:None] (the stream composer doesn't know the
      LLM's finish reason) and [~is_aborted:true] if [execute] raised.
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
    a cohttp response with UIMessage protocol headers.

    @param cors Include CORS headers (default: [true]). *)
val create_ui_message_stream_response :
  ?status:Cohttp.Code.status_code ->
  ?headers:(string * string) list ->
  ?cors:bool ->
  Ui_message_chunk.t Lwt_stream.t ->
  (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t
