(** Tool definition for function calling. *)

type t = {
  name : string;
  description : string option;
  parameters : Jsonkit.t;  (** JSON Schema *)
  provider_options : Provider_options.t;
}
