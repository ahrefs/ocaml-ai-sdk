(** Transform OpenAI SSE events into SDK stream parts.

    Handles OpenAI's streaming format where tool calls are accumulated
    by index within [delta.tool_calls] arrays, and the stream terminates
    with [data: \[DONE\]]. *)
val transform : Sse.event Lwt_stream.t -> warnings:Ai_provider.Warning.t list -> Ai_provider.Stream_part.t Lwt_stream.t
