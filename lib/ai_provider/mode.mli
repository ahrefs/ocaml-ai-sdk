(** Generation mode -- controls the shape of model output. *)

type json_schema = {
  name : string;
  schema : Yojson.Basic.t;
}

type t =
  | Regular
  | Object_json of json_schema option
  | Object_tool of {
      tool_name : string;
      schema : json_schema;
    }

(** Tool name used by providers that don't natively enforce JSON Schema: they
    synthesise a tool by this name with the caller's schema as [inputSchema],
    force [tool_choice] to it, and decode the result from the [tool_use] args.
    Matches the upstream Vercel AI SDK convention. *)
val fallback_json_tool_name : string
