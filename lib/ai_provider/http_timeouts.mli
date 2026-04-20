(** HTTP timeout configuration.

    These are conservative defaults meant to catch stuck connections and
    bugs, not to bound legitimate workloads. A 20-minute streaming
    response is fine as long as chunks keep arriving: [stream_idle_timeout]
    is inter-chunk, not cumulative. *)

type t = private {
  request_timeout : float;
      (** Seconds until response headers arrive. Covers TCP connect, TLS
          handshake, request body write, and the server's processing time
          before it starts the response. Default: [600.0] (10 minutes). *)
  stream_idle_timeout : float;
      (** Seconds allowed between consecutive streaming body chunks. Resets
          on each chunk. Default: [300.0] (5 minutes). *)
}

val default : t
(** [request_timeout = 600.0; stream_idle_timeout = 300.0]. *)

val create : ?request_timeout:float -> ?stream_idle_timeout:float -> unit -> t
(** Override one or both defaults. Values must be positive; non-positive
    values raise [Invalid_argument]. *)
