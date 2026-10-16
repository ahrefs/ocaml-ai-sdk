(** HTTP client for provider API calls, built on libcurl through [Curl_lwt].

    [timeouts.request_timeout] bounds the wait for response headers and
    [timeouts.stream_idle_timeout] bounds the gap between body chunks. Timeouts
    and transport failures fail with [Provider_error.Provider_error]. *)

type response

(** POSTs [body] to the URL and resolves once the final (non-1xx) response
    headers arrive. Fails with a [Request_headers] timeout after
    [timeouts.request_timeout], or with [Network_error] when the transfer fails
    before headers. Cancelling the returned promise aborts the transfer. *)
val post :
  timeouts:Http_timeouts.t ->
  provider:string ->
  headers:(string * string) list ->
  body:string ->
  string ->
  response Lwt.t

val status : response -> int

(** Case-insensitive header lookup. *)
val header : response -> string -> string option

(** Reads the whole body. Fails with [Network_error] on a transport failure, or
    with a [Stream_idle] timeout when no chunk arrives within
    [timeouts.stream_idle_timeout]; both abort the transfer. *)
val body_string : response -> string Lwt.t

(** The body as lines (split on LF, CR stripped), with the same idle timer as
    [body_string]. The returned stream:
    - Emits one line per LF-terminated segment.
    - Flushes any trailing buffered data on normal end-of-stream.
    - Is cleanly closed on idle timeout, transport failure, or normal
      completion, so no consumer hangs.
    - On failure, re-raises the error to [Lwt.async_exception_hook] after the
      stream is closed, and aborts the transfer. *)
val body_lines : response -> string Lwt_stream.t

(** A response whose body comes from in-memory chunks; [body_string] and
    [body_lines] behave as for a network response. Intended for tests. *)
val response_of_chunks :
  timeouts:Http_timeouts.t ->
  provider:string ->
  status:int ->
  headers:(string * string) list ->
  string Lwt_stream.t ->
  response
