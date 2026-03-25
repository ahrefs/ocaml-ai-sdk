(** JSON Schema Draft-07 subset validator.

    Validates a [Yojson.Basic.t] value against a JSON Schema.
    Supports: type, properties, required, additionalProperties,
    items, enum. Sufficient for structured output validation. *)

(** [validate ~schema json] returns [Ok ()] if [json] conforms to [schema],
    or [Error msg] describing the first validation failure. *)
val validate : schema:Yojson.Basic.t -> Yojson.Basic.t -> (unit, string) result
