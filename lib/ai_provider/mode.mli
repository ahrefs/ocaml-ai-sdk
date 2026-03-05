(** Generation mode -- controls the shape of model output. *)

type json_schema = {
  name : string;
  schema : Yojson.Safe.t;
}

type t =
  | Regular
  | Object_json of json_schema option
  | Object_tool of {
      tool_name : string;
      schema : json_schema;
    }
