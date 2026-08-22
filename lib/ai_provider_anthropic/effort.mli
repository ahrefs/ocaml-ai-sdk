(** Anthropic output effort levels. *)

type t =
  | Low
  | Medium
  | High
  | Xhigh
  | Max

val to_string : t -> string

val equal : t -> t -> bool
