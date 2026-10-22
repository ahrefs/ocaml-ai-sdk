(** Runs a provider's per-event stream converter in the background.

    Providers use this to turn an SSE event stream into {!Stream_part.t}
    parts. *)

(** [pump ?abort_signal ~provider ~push f events] runs [f] on each event in
    the background, then closes the output with [push None], whatever
    happens. Every error part it creates is non-retryable and names
    [provider]. A [Provider_error] keeps its own fields.

    When [f] raises a JSON decode error, a [Deserialization_error] whose [raw]
    is the event's data is pushed, and the next event is processed. The decode
    errors are [Yojson.Json_error], Yojson's [End_of_array], [End_of_object]
    and [End_of_input], the [Type_error] and [Undefined] of both
    [Yojson.Basic.Util] and [Yojson.Safe.Util], [Melange_json.Of_json_error]
    and [Melange_json.Of_string_error].

    Any other exception, raised by [events] or by [f], is pushed as an [Error]
    part and ends the stream. A [Provider_error] is pushed as it is. Anything
    else becomes an [Unexpected_error] whose message is the exception as
    [Printexc.to_string] prints it. Once [abort_signal], the call's signal,
    has fired, [Abort_signal.Aborted] and [Lwt.Canceled] end the stream
    without an [Error] part: the caller asked for them. Before then, or with
    no signal, they are [Unexpected_error]s like any other exception. *)
val pump :
  ?abort_signal:Abort_signal.t ->
  provider:string ->
  push:(Stream_part.t option -> unit) ->
  (Sse.event -> unit) ->
  Sse.event Lwt_stream.t ->
  unit
