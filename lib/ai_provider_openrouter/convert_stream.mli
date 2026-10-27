(** OpenRouter SSE stream conversion. *)

(** Extract response identity from the first completion chunk without consuming
    the stream. Empty debug chunks from failed fallback attempts are skipped. *)
val response_info : Sse.event Lwt_stream.t -> Ai_provider.Generate_result.response_info option Lwt.t

(** [response_info], returned with the stream to convert. When reading the
    response info fails, the info is [None] and the returned stream yields the
    events read so far, then fails with the same exception, so {!transform}
    reports it. *)
val peek_response_info :
  Sse.event Lwt_stream.t -> (Ai_provider.Generate_result.response_info option * Sse.event Lwt_stream.t) Lwt.t

(** Transform SSE events into SDK stream parts.
    Handles reasoning deltas and extended usage metrics.

    @param abort_signal The call's signal. Once it has fired, an abort or
      cancel ends the parts without an [Error] part, as
      {!Ai_provider.Stream_pump.pump} describes. *)
val transform :
  ?abort_signal:Ai_provider.Abort_signal.t ->
  Sse.event Lwt_stream.t ->
  warnings:Ai_provider.Warning.t list ->
  Ai_provider.Stream_part.t Lwt_stream.t
