(** Extended thinking configuration for Claude models. *)

(** Thinking budget — always >= 1024 tokens.
    Use [budget] or [budget_exn] to construct. *)
type budget_tokens = private int

(** Returns [Error] if budget < 1024. *)
val budget : int -> (budget_tokens, string) result

(** Raises [Invalid_argument] if budget < 1024. *)
val budget_exn : int -> budget_tokens

(** Extract the integer value. *)
val to_int : budget_tokens -> int

type t = {
  enabled : bool;
  budget_tokens : budget_tokens;
}
