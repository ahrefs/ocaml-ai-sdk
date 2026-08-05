(** OpenRouter SSE stream conversion. *)

(** Extract response identity from the first completion chunk without consuming
    the stream. Empty debug chunks from failed fallback attempts are skipped. *)
val response_info : Sse.event Lwt_stream.t -> Ai_provider.Generate_result.response_info option Lwt.t

(** Transform SSE events into SDK stream parts.
    Handles reasoning deltas and extended usage metrics. *)
val transform : Sse.event Lwt_stream.t -> warnings:Ai_provider.Warning.t list -> Ai_provider.Stream_part.t Lwt_stream.t
