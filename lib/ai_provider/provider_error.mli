(** Errors from provider API calls. *)

type timeout_phase =
  | Request_headers  (** Not retryable: the server may already be processing the request. *)
  | Stream_idle  (** Retryable: the connection has gone silent and is treated as dead. *)

type error_kind =
  | Api_error of {
      status : int;
      body : string;
    }
  | Network_error of { message : string }
  | Deserialization_error of {
      message : string;
      raw : string;
    }
  | Timeout of {
      phase : timeout_phase;
      elapsed_s : float;
      limit_s : float;
    }

type t = {
  provider : string;
  kind : error_kind;
  is_retryable : bool;
}

exception Provider_error of t

(** Construct an API error.

    When [is_retryable] is omitted, defaults to the upstream status-code
    heuristic: 408, 409, 429, or any 5xx are retryable. Providers may
    override this when they can parse the error type from the response body. *)
val make_api_error : provider:string -> status:int -> body:string -> ?is_retryable:bool -> unit -> t

(** Construct a timeout error. [is_retryable] is derived from [phase]:
    [Request_headers] is not retryable (server may already be processing
    the request; retry risks double-billing); [Stream_idle] is retryable
    (stream is dead, safe to start over). *)
val make_timeout : provider:string -> phase:timeout_phase -> elapsed_s:float -> limit_s:float -> t

val to_string : t -> string
