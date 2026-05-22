(** Track [cache_control] breakpoints across a single Anthropic request.
    Anthropic allows at most 4 explicit breakpoints; the 5th+ is dropped
    and an [Unsupported_feature] warning is emitted. *)

type t

val create : unit -> t

(** Consume a cache_control value, returning it if a slot is still available
    or [None] (after recording a warning) once the limit is exceeded. *)
val take : t -> Cache_control.t option -> Cache_control.t option

(** Warnings accumulated by [take], in insertion order. *)
val warnings : t -> Ai_provider.Warning.t list
