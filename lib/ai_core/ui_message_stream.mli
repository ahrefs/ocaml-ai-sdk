(** SSE encoding for the UIMessage stream protocol.

    Encodes [Ui_message_chunk.t] values as Server-Sent Events compatible
    with the Vercel AI SDK frontend ([useChat]). *)

(** Required HTTP response headers for UIMessage stream protocol v1. *)
val headers : (string * string) list

(** Encode a chunk as an SSE data line: ["data: {json}\n\n"]. *)
val chunk_to_sse : Ui_message_chunk.t -> string

(** Terminal SSE message: ["data: [DONE]\n\n"]. *)
val done_sse : string

(** Transform a chunk stream into an SSE string stream.
    Appends the [DONE] sentinel when the input stream ends. *)
val stream_to_sse : Ui_message_chunk.t Lwt_stream.t -> string Lwt_stream.t
