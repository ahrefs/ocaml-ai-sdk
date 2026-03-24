(** Prompt caching control for Anthropic models. *)

type breakpoint = Ephemeral  (** Cache control type. Currently only [Ephemeral] is supported. *)

type t = { cache_type : breakpoint }

(** Convenience constructor for ephemeral cache control. *)
val ephemeral : t

(** Returns JSON fields for cache control. Empty list if [None]. *)
val to_yojson_fields : t option -> (string * Yojson.Safe.t) list
