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

val to_string : t -> string
