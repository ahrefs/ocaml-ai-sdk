(** Errors from provider API calls. *)

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

val to_string : t -> string
