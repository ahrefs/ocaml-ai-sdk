open Melange_json.Primitives

type openai_function_def = {
  name : string;
  description : string option; [@json.option] [@json.drop_default]
  parameters : Melange_json.t;
  strict : bool option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type openai_tool = {
  type_ : string; [@json.key "type"]
  function_ : openai_function_def; [@json.key "function"]
}
[@@deriving to_json]

type tool_choice_function = { name : string } [@@deriving to_json]

type tool_choice_specific = {
  type_ : string; [@json.key "type"]
  function_ : tool_choice_function; [@json.key "function"]
}
[@@deriving to_json]

let convert_single_tool ~strict (tool : Ai_provider.Tool.t) : openai_tool =
  let strict_opt =
    match strict with
    | true -> Some true
    | false -> None
  in
  {
    type_ = "function";
    function_ = { name = tool.name; description = tool.description; parameters = tool.parameters; strict = strict_opt };
  }

let convert_tools ~strict tools = List.map (convert_single_tool ~strict) tools

let convert_tool_choice (tc : Ai_provider.Tool_choice.t) : Melange_json.t =
  match tc with
  | Auto -> `String "auto"
  | Required -> `String "required"
  | None_ -> `String "none"
  | Specific { tool_name } -> tool_choice_specific_to_json { type_ = "function"; function_ = { name = tool_name } }
