(** Convert SDK tools and tool choice to Anthropic format. *)

type anthropic_tool = {
  name : string;
  description : string option;
  input_schema : Yojson.Safe.t;
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

val anthropic_tool_to_yojson : anthropic_tool -> Yojson.Safe.t
val anthropic_tool_choice_to_yojson : anthropic_tool_choice -> Yojson.Safe.t
