open Melange_json.Primitives

type cc = Cache_control.t

let cc_to_json (cc : cc) = Cache_control.breakpoint_to_json cc.cache_type

type anthropic_tool = {
  name : string;
  description : string option; [@json.option] [@json.drop_default]
  input_schema : Melange_json.t;
  cache_control : cc option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type tool_choice_type_json = { type_ : string [@json.key "type"] } [@@deriving to_json]

type tool_choice_specific_json = {
  type_ : string; [@json.key "type"]
  name : string;
}
[@@deriving to_json]

type anthropic_tool_choice =
  | Tc_auto
  | Tc_any
  | Tc_tool of { name : string }

let convert_single_tool (tool : Ai_provider.Tool.t) : anthropic_tool =
  { name = tool.name; description = tool.description; input_schema = tool.parameters; cache_control = None }

let convert_tools ~tools ~tool_choice =
  match tool_choice with
  | Some Ai_provider.Tool_choice.None_ -> [], None
  | None | Some Ai_provider.Tool_choice.Auto -> List.map convert_single_tool tools, Some Tc_auto
  | Some Ai_provider.Tool_choice.Required -> List.map convert_single_tool tools, Some Tc_any
  | Some (Ai_provider.Tool_choice.Specific { tool_name }) ->
    List.map convert_single_tool tools, Some (Tc_tool { name = tool_name })

let anthropic_tool_choice_to_json = function
  | Tc_auto -> tool_choice_type_json_to_json { type_ = "auto" }
  | Tc_any -> tool_choice_type_json_to_json { type_ = "any" }
  | Tc_tool { name } -> tool_choice_specific_json_to_json { type_ = "tool"; name }

let json_response_tool ~schema =
  {
    name = Ai_provider.Mode.fallback_json_tool_name;
    description = Some "Respond with a JSON object using this tool.";
    input_schema = schema;
    cache_control = None;
  }

let forced_json_tool_choice = Tc_tool { name = Ai_provider.Mode.fallback_json_tool_name }
