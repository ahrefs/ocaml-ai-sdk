(** Provider-specific options using an extensible GADT.
    Each provider registers its own typed key without circular dependencies.

    Implementation uses {!Obj.Extension_constructor.id} for key identity
    and {!Obj.magic} for type recovery — type-safe by construction since
    matching extension constructor IDs guarantee identical type parameters.
    This is the standard pattern used by {!Printexc} and other stdlib modules.
    OCaml 5.1+ [Type.eq] would replace this with a first-class witness. *)

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

(** GADT key for raw provider metadata from upstream re-submissions.
    Stores the upstream [providerMetadata] JSON blob
    ([Record<string, Record<string, JsonValue>>]). Each provider reads
    its own namespace (e.g. ["anthropic"]). *)
type _ key += Provider_metadata : Yojson.Basic.t key

(** Create a [t] containing only raw provider metadata. *)
val of_provider_metadata : Yojson.Basic.t -> t

(** Extract raw provider metadata if present. *)
val provider_metadata : t -> Yojson.Basic.t option
