(** Tool definition for the Core SDK.

    Tools have a description, JSON Schema parameters, and an execute function
    that takes JSON args and returns JSON results. *)

type t = {
  description : string option;
  parameters : Yojson.Safe.t;  (** JSON Schema for tool parameters *)
  execute : Yojson.Safe.t -> Yojson.Safe.t Lwt.t;  (** Execute the tool. Args and result are both JSON. *)
}

(** Parse a JSON string, falling back to [`String s] on parse error. *)
val safe_parse_json_args : string -> Yojson.Safe.t
