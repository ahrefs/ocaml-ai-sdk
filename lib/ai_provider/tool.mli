(** Tool definition for function calling. *)

type t = {
  name : string;
  description : string option;
  parameters : Yojson.Safe.t;  (** JSON Schema *)
}
