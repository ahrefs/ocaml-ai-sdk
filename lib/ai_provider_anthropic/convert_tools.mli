(** Convert SDK tools and tool choice to Anthropic format. *)

type anthropic_tool = {
  name : string;
  description : string option;
  input_schema : Yojson.Basic.t;
  cache_control : Cache_control.t option;
}

type anthropic_tool_choice =
  | Tc_auto
  | Tc_any
  | Tc_tool of { name : string }

(** Convert SDK tools and choice. [Tool_choice.None_] returns empty tools.
    [Tool_choice.Required] maps to [Tc_any]. *)
val convert_tools :
  tools:Ai_provider.Tool.t list ->
  tool_choice:Ai_provider.Tool_choice.t option ->
  anthropic_tool list * anthropic_tool_choice option

val anthropic_tool_to_json : anthropic_tool -> Yojson.Basic.t
val anthropic_tool_choice_to_json : anthropic_tool_choice -> Yojson.Basic.t

(** Build the synthetic [json] tool used as a fallback for structured outputs on
    models that don't support Anthropic's native [output_config.format]. The tool is
    always named [json] — matching upstream [@ai-sdk/anthropic] — and carries the
    user-supplied schema as its [input_schema]. The caller is responsible for forcing
    [tool_choice] to this tool (see [forced_json_tool_choice]). *)
val json_response_tool : schema:Yojson.Basic.t -> anthropic_tool

(** Tool choice forcing the model to emit only the synthetic [json] tool. *)
val forced_json_tool_choice : anthropic_tool_choice
