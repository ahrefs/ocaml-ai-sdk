(** Convert SDK tools and tool_choice to OpenAI format. *)

type openai_function_def = {
  name : string;
  description : string option;
  parameters : Melange_json.t;
  strict : bool option;
}

type openai_tool = {
  type_ : string;
  function_ : openai_function_def;
}

val openai_tool_to_json : openai_tool -> Melange_json.t

(** Convert a list of SDK tools to OpenAI typed format.
    [strict] controls whether strict JSON schema validation is enabled. *)
val convert_tools : strict:bool -> Ai_provider.Tool.t list -> openai_tool list

(** Convert SDK tool_choice to OpenAI JSON format. *)
val convert_tool_choice : Ai_provider.Tool_choice.t -> Melange_json.t
