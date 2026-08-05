(** OpenRouter SSE stream conversion. *)

(** Extract response identity from an SSE chunk when present. *)
val response_info_of_event : Sse.event -> Ai_provider.Generate_result.response_info option

(** Transform SSE events into SDK stream parts.
    Handles reasoning deltas and extended usage metrics. *)
val transform : Sse.event Lwt_stream.t -> warnings:Ai_provider.Warning.t list -> Ai_provider.Stream_part.t Lwt_stream.t
