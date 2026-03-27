(** Server-Sent Events parser for streaming API responses. *)

type event = {
  event_type : string;
  data : string;
}

(** Parse a stream of SSE text lines into typed events.
    Handles multi-line data, event type prefixes, comments, and blank lines. *)
val parse_events : string Lwt_stream.t -> event Lwt_stream.t
