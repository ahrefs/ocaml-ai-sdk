(** Prompt caching control for Anthropic models. *)

type breakpoint = Ephemeral  (** Cache control type. Currently only [Ephemeral] is supported. *)

(** Cache TTL. Anthropic accepts ["5m"] (default) or ["1h"]. *)
type ttl =
  | Ttl_5m
  | Ttl_1h

type t = {
  cache_type : breakpoint;
  ttl : ttl option;
}

(** Ephemeral cache control with default 5-minute TTL. *)
val ephemeral : t

(** Ephemeral cache control with explicit 1-hour TTL. *)
val ephemeral_1h : t

val to_json : t -> Yojson.Basic.t
val of_json : Yojson.Basic.t -> t

(** Returns JSON fields for cache control. Empty list if [None]. *)
val to_json_fields : t option -> (string * Yojson.Basic.t) list
