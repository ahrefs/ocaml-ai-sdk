(** Structured output API for generate_text and stream_text.

    Matches the Vercel AI SDK v6 Output API: [Output.text], [Output.object_],
    [Output.array], [Output.choice]. Controls model response format and adds
    parsing/validation. *)

(** An output specification parameterized by the parsed output type.
    - ['complete] is the type returned by [parse_complete] (final validated output)
    - ['partial] is the type returned by [parse_partial] (streaming partial output) *)
type ('complete, 'partial) t = {
  name : string;
  response_format : Ai_provider.Mode.json_schema option;
    (** Schema to pass to the provider via [Mode.Object_json].
          [None] means text mode (no JSON instruction). *)
  parse_complete : string -> ('complete, string) result;
    (** Parse and validate the complete model response text.
          Returns [Error msg] if JSON parsing or schema validation fails. *)
  parse_partial : string -> 'partial option;
    (** Parse a potentially incomplete response for streaming.
          Returns [None] if text is empty or unparseable. No schema validation. *)
}

(** Derive the provider [Mode.t] from an optional output spec.
    [Some o] with a schema maps to [Object_json]; otherwise [Regular]. *)
val mode_of_output : (_, _) t option -> Ai_provider.Mode.t

(** Parse the final output from completed steps. Returns [None] if no
    output spec, text mode, or parse failure. *)
val parse_output : (Yojson.Basic.t, _) t option -> Generate_text_result.step list -> Yojson.Basic.t option

(** Default text output — no structured format, returns raw text. *)
val text : (string, string) t

(** Object output — model produces JSON matching the given schema.
    [name] is passed to the provider for context.
    Complete output is validated against the schema.
    Partial output uses repair-and-parse (no validation). *)
val object_ : name:string -> schema:Yojson.Basic.t -> unit -> (Yojson.Basic.t, Yojson.Basic.t) t

(** Array output — model produces an array of elements matching the schema.
    Wraps in [{"elements":[...]}] envelope for the model, unwraps on parse.
    Complete output validates every element against the schema.
    Partial output drops the last element on repaired parses and
    silently skips invalid elements. *)
val array : name:string -> element_schema:Yojson.Basic.t -> unit -> (Yojson.Basic.t, Yojson.Basic.t) t

(** Choice output — model picks one of the given string options.
    Wraps in [{"result":"..."}] envelope for the model, unwraps on parse.
    Complete output validates the choice is in the allowed list.
    Partial output uses prefix matching: on repaired parses, only returns
    when exactly one option matches the prefix (unambiguous). *)
val choice : name:string -> string list -> (Yojson.Basic.t, Yojson.Basic.t) t

(** @deprecated Use [choice] instead. Alias kept for backwards compatibility. *)
val enum : name:string -> string list -> (Yojson.Basic.t, Yojson.Basic.t) t
