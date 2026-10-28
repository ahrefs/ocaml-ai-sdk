(** Typed tools.

    A {!type-t} pairs a name and description with codecs for its call (the
    arguments the model supplies) and its response, and a [run] function on
    the decoded values. Unlike {!Core_tool.t}, whose [execute] works on raw
    JSON, [run] sees OCaml values. *)

(** Conversion of ['a] to and from JSON, with its JSON Schema. *)
type 'a codec = {
  to_json : 'a -> Yojson.Basic.t;
  of_json : Yojson.Basic.t -> ('a, string) result;
  schema : Yojson.Basic.t;  (** JSON Schema describing the encoded value. *)
}

(** Build a codec from [melange-json] derivers, whose [of_json] raises on
    failure. [Melange_json.Of_json_error] and [Melange_json.Of_string_error]
    become [Error].

    {[
      type args = { city : string } [@@deriving json]

      let args_codec =
        Tool.codec ~to_json:args_to_json ~of_json:args_of_json ~schema:args_schema
    ]} *)
val codec : to_json:('a -> Yojson.Basic.t) -> of_json:(Yojson.Basic.t -> 'a) -> schema:Yojson.Basic.t -> 'a codec

(** What a failing tool reports. [message] is shown to the model; [data] is
    optional structured detail. *)
type error = {
  message : string;
  data : Yojson.Basic.t option;
}

(** Raised by {!to_core_tool}'s [execute] when the tool returns an [Error].
    Its registered printer omits the exception name, so [generate_text] shows
    the model just the message (and data, if any). *)
exception Failed of error

type t

(** [run] receives the same {!Core_tool.execute_options} as a core tool, so it
    can watch the abort signal. [needs_approval] is checked by {!to_core_tool}'s
    tool, not by {!execute}. *)
val create :
  ?description:string ->
  ?needs_approval:('c -> bool Lwt.t) ->
  name:string ->
  call:'c codec ->
  response:'r codec ->
  run:(Core_tool.execute_options -> 'c -> ('r, error) result Lwt.t) ->
  unit ->
  t

val name : t -> string
val description : t -> string option

(** JSON Schema of the call, as sent to the model. *)
val call_schema : t -> Yojson.Basic.t

(** JSON Schema of the response. *)
val response_schema : t -> Yojson.Basic.t

(** [execute tool args options] decodes [args], runs the tool and encodes the
    response. Arguments that do not decode give an [Error] whose message
    starts with ["Invalid arguments"], without running the tool; a response
    that does not encode, one starting with ["Invalid response"]. Exceptions
    raised by the codecs become such errors; those raised by [run] propagate. *)
val execute : t -> Yojson.Basic.t -> Core_tool.execute_options -> (Yojson.Basic.t, error) result Lwt.t

(** The name and {!Core_tool.t} to register under [~tools]. A returned [Error]
    is raised as {!Failed}. Arguments that do not decode need no approval: the
    call then fails without running the tool. *)
val to_core_tool : ?provider_options:Ai_provider.Provider_options.t -> t -> string * Core_tool.t
