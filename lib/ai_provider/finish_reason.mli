(** Reason why model generation finished. *)

type t =
  | Stop
  | Length
  | Tool_calls
  | Content_filter
  | Error
  | Other of string
  | Unknown

val to_string : t -> string
val of_string : string -> t
