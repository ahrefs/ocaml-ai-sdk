(** Transform OpenAI SSE events into SDK stream parts.

    Handles OpenAI's streaming format where tool calls are accumulated
    by index within [delta.tool_calls] arrays, and the stream terminates
    with [data: \[DONE\]].

    @param abort_signal The call's signal. Once it has fired, an abort or
      cancel ends the parts without an [Error] part, as
      {!Ai_provider.Stream_pump.pump} describes. *)
val transform :
  ?abort_signal:Ai_provider.Abort_signal.t ->
  Sse.event Lwt_stream.t ->
  warnings:Ai_provider.Warning.t list ->
  Ai_provider.Stream_part.t Lwt_stream.t
