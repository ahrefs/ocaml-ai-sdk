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

(* The Vercel AI SDK convention for providers that don't natively enforce JSON Schema:
   synthesize a tool called "json" whose inputSchema is the caller's schema, force the
   model to call it, and decode the response from the tool_use args. Upstream
   [@ai-sdk/anthropic] uses this exact name; changing it would break interop. *)
let fallback_json_tool_name = "json"
