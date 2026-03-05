(** Provider-specific options using an extensible GADT.
    Each provider registers its own typed key without circular dependencies. *)

(** Extensible GADT — each provider adds a constructor via [+=]. *)
type _ key = ..

(** Existential wrapper: a typed key paired with its value. *)
type entry = Entry : 'a key * 'a -> entry

(** A bag of provider-specific options. *)
type t = entry list

val empty : t

(** Add or replace an option keyed by the GADT constructor. *)
val set : 'a key -> 'a -> t -> t

(** Look up an option by key. Returns [None] if absent. *)
val find : 'a key -> t -> 'a option

(** Look up an option by key. Raises [Not_found] if absent. *)
val find_exn : 'a key -> t -> 'a
