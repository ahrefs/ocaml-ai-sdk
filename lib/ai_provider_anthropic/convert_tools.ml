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

let convert_single_tool (tool : Ai_provider.Tool.t) : anthropic_tool =
  { name = tool.name; description = tool.description; input_schema = tool.parameters; cache_control = None }

let convert_tools ~tools ~tool_choice =
  match tool_choice with
  | Some Ai_provider.Tool_choice.None_ -> [], None
  | None | Some Ai_provider.Tool_choice.Auto -> List.map convert_single_tool tools, Some Tc_auto
  | Some Ai_provider.Tool_choice.Required -> List.map convert_single_tool tools, Some Tc_any
  | Some (Ai_provider.Tool_choice.Specific { tool_name }) ->
    List.map convert_single_tool tools, Some (Tc_tool { name = tool_name })

let anthropic_tool_to_yojson tool =
  let fields =
    List.concat
      [
        [ "name", `String tool.name; "input_schema", tool.input_schema ];
        (match tool.description with
        | Some d -> [ "description", `String d ]
        | None -> []);
        Cache_control.to_yojson_fields tool.cache_control;
      ]
  in
  `Assoc fields

let anthropic_tool_choice_to_yojson = function
  | Tc_auto -> `Assoc [ "type", `String "auto" ]
  | Tc_any -> `Assoc [ "type", `String "any" ]
  | Tc_tool { name } -> `Assoc [ "type", `String "tool"; "name", `String name ]
