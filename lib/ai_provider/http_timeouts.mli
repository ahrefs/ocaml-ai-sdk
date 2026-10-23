(** HTTP timeout configuration.

    These are conservative defaults meant to catch stuck connections and
    bugs, not to bound legitimate workloads. A 20-minute streaming
    response is fine as long as chunks keep arriving: [stream_idle_timeout]
    is inter-chunk, not cumulative. *)

type t = private {
  connect_timeout : float;
    (** Seconds to establish the connection: DNS, TCP connect and TLS
          handshake. When it fires, the request fails with a retryable
          [Network_error], since nothing has reached the server. Both clocks
          start with the request, so it takes effect only while it is below
          [request_timeout]. Otherwise a stalled connection fails with the
          non-retryable [Timeout { phase = Request_headers }].
          Default: [10.0]. *)
  request_timeout : float;
    (** Seconds until response headers arrive. Covers TCP connect, TLS
          handshake, request body write, and the server's processing time
          before it starts the response. Default: [600.0] (10 minutes). *)
  stream_idle_timeout : float;
    (** Seconds a body read may wait for the next chunk. Resets on each
          chunk. Default: [300.0] (5 minutes). *)
}

(** [connect_timeout = 10.0; request_timeout = 600.0; stream_idle_timeout = 300.0]. *)
val default : t

(** Override any of the defaults. Values must be positive; non-positive
    values raise [Invalid_argument]. *)
val create : ?connect_timeout:float -> ?request_timeout:float -> ?stream_idle_timeout:float -> unit -> t
