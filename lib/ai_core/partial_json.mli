(** Partial JSON parser — repairs truncated JSON for streaming.

    When a model is mid-generation, JSON may be incomplete (unclosed brackets,
    truncated strings). This module attempts to repair and parse such input. *)

type parse_status =
  | Successful  (** Input was valid JSON as-is *)
  | Repaired  (** Input was repaired (truncated content closed) *)

(** [parse input] attempts to parse potentially incomplete JSON.
    Returns [Some (json, status)] on success, [None] if input is empty or
    cannot be repaired. Repair strategy: close unclosed strings, arrays,
    objects; drop trailing incomplete key-value pairs. *)
val parse : string -> (Jsonkit.t * parse_status) option
