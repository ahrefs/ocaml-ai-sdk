(** Strict CBOR subset used by the tiny-js-sandbox wire protocol (see [lib/tiny-js-sandbox/PROTOCOL.md]).

    Supported: unsigned integers up to [2^53 - 1], byte strings, text strings (valid UTF-8), booleans, [null], definite
    length arrays and definite length maps with text keys. Everything else (negative integers, tags, floats,
    [undefined], other simple values, indefinite lengths) is rejected by the decoder. *)

type t =
  | Null
  | Bool of bool
  | Int of int  (** unsigned, [0 .. max_uint] *)
  | Text of string  (** UTF-8 *)
  | Bytes of string
  | Array of t list
  | Map of (string * t) list  (** text keys, in order, no duplicates when decoded *)

(** Largest accepted integer, [2^53 - 1] (exactly representable in JavaScript). *)
val max_uint : int

(** Default container nesting limit of {!decode}: 16. *)
val default_max_depth : int

(** Shortest-form, definite-length encoding.
    @raise Invalid_argument if an [Int] is negative or above {!max_uint}, or a [Text]/map key is not valid UTF-8. *)
val encode : t -> string

(** Decode exactly one item. Fails on trailing bytes, truncated input, anything outside the subset, duplicate map keys,
    invalid UTF-8, and containers nested deeper than [max_depth] (default {!default_max_depth}; a scalar at top level
    has depth 0). Declared lengths are checked against the remaining input before anything is allocated. *)
val decode : ?max_depth:int -> string -> (t, string) result

val equal : t -> t -> bool

(** Diagnostic printer. *)
val pp : Format.formatter -> t -> unit

(** Strict accessors over the fields of a decoded {!Map}; errors are prefixed with the [frame] name. *)
module Parse : sig
  (** The map has exactly these keys, in any order. *)
  val exact_keys : frame:string -> (string * t) list -> string list -> (unit, string) result

  val text_field : frame:string -> string -> (string * t) list -> (string, string) result
  val int_field : frame:string -> string -> (string * t) list -> (int, string) result
  val bool_field : frame:string -> string -> (string * t) list -> (bool, string) result
end
