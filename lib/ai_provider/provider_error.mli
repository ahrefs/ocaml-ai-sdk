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

(** Construct an API error with the given retryable status. *)
val make_api_error : provider:string -> status:int -> body:string -> is_retryable:bool -> t

val to_string : t -> string
