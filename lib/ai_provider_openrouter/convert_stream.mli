(** OpenRouter SSE stream conversion. *)

(** Transform SSE events into SDK stream parts.
    Handles reasoning deltas and extended usage metrics. *)
val transform :
  Sse.event Lwt_stream.t -> warnings:Ai_provider.Warning.t list -> Ai_provider.Stream_part.t Lwt_stream.t
