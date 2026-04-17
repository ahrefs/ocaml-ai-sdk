(** HTTP client wrappers that apply [Http_timeouts] to cohttp calls.

    These are the defence-in-depth layer around [Cohttp_lwt_unix.Client.post]
    and the response body stream. All provider implementations should use
    these instead of raw cohttp calls. *)

val post :
  timeouts:Http_timeouts.t ->
  provider:string ->
  headers:Cohttp.Header.t ->
  body:Cohttp_lwt.Body.t ->
  Uri.t ->
  (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t
(** Wraps [Cohttp_lwt_unix.Client.post] in [Lwt_unix.with_timeout] using
    [timeouts.request_timeout]. On expiry, fails with
    [Provider_error.Provider_error (Timeout { phase = Request_headers; ... })]
    tagged with the given [provider] string. *)

val wrap_body_with_idle_timeout :
  timeouts:Http_timeouts.t ->
  provider:string ->
  Cohttp_lwt.Body.t ->
  string Lwt_stream.t
(** Converts a cohttp body into a line stream (splits on LF, strips CR),
    with an inter-chunk idle timer from [timeouts.stream_idle_timeout].
    The returned stream:
    - Emits one line per LF-terminated segment.
    - Flushes any trailing buffered data on normal end-of-stream.
    - Is cleanly closed (consumers see end-of-stream) on idle timeout,
      body-stream exception, or normal completion — no consumer will hang.
    - On exception, the original exception is re-raised to
      [Lwt.async_exception_hook] after the stream is closed, so bugs stay
      visible in logs.

    Safe because the internal [Lwt_stream.feed] uses [Lwt.protected],
    which prevents [Lwt.pick]'s cancellation from corrupting stream state. *)
