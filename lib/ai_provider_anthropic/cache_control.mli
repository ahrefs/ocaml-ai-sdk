(** Prompt caching control for Anthropic models. *)

type breakpoint = Ephemeral  (** Cache control type. Currently only [Ephemeral] is supported. *)

type t = { cache_type : breakpoint }

(** Convenience constructor for ephemeral cache control. *)
val ephemeral : t

val breakpoint_to_json : breakpoint -> Yojson.Basic.t
val breakpoint_of_json : Yojson.Basic.t -> breakpoint

val to_json : t -> Yojson.Basic.t
val of_json : Yojson.Basic.t -> t

(** Returns JSON fields for cache control. Empty list if [None]. *)
val to_json_fields : t option -> (string * Yojson.Basic.t) list
