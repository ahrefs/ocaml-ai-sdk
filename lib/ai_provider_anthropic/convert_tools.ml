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
  | Some Ai_provider.Tool_choice.None_ ->
    (* None_ means don't use tools at all *)
    [], None
  | _ ->
    let anthropic_tools = List.map convert_single_tool tools in
    let choice =
      match tool_choice with
      | None | Some Ai_provider.Tool_choice.Auto -> Some Tc_auto
      | Some Ai_provider.Tool_choice.Required -> Some Tc_any
      | Some (Ai_provider.Tool_choice.Specific { tool_name }) -> Some (Tc_tool { name = tool_name })
      | Some Ai_provider.Tool_choice.None_ ->
        (* Already handled above, but exhaustive matching *)
        None
    in
    anthropic_tools, choice

let anthropic_tool_to_yojson tool =
  let fields = [ "name", `String tool.name; "input_schema", tool.input_schema ] in
  let fields =
    match tool.description with
    | Some d -> ("description", `String d) :: fields
    | None -> fields
  in
  let fields =
    match tool.cache_control with
    | Some cc ->
      (match cc.Cache_control.cache_type with
      | Ephemeral -> fields @ [ "cache_control", `Assoc [ "type", `String "ephemeral" ] ])
    | None -> fields
  in
  `Assoc fields

let anthropic_tool_choice_to_yojson = function
  | Tc_auto -> `Assoc [ "type", `String "auto" ]
  | Tc_any -> `Assoc [ "type", `String "any" ]
  | Tc_tool { name } -> `Assoc [ "type", `String "tool"; "name", `String name ]
