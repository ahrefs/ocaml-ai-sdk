open Melange_json.Primitives
open Alcotest

type tool_json = {
  name : string;
  input_schema : Melange_json.t;
  description : string option; [@json.default None]
} [@@json.allow_extra_fields] [@@deriving of_json]

let test_single_tool () =
  let tools : Ai_provider.Tool.t list =
    [ { name = "search"; description = Some "Search the web"; parameters = `Assoc [ "type", `String "object" ] } ]
  in
  let result, choice = Ai_provider_anthropic.Convert_tools.convert_tools ~tools ~tool_choice:None in
  (check int) "1 tool" 1 (List.length result);
  let tool = List.nth result 0 in
  (check string) "name" "search" tool.name;
  (check (option string)) "desc" (Some "Search the web") tool.description;
  (check bool) "auto choice" true (Option.is_some choice)

let test_tool_choice_auto () =
  let _, choice =
    Ai_provider_anthropic.Convert_tools.convert_tools ~tools:[] ~tool_choice:(Some Ai_provider.Tool_choice.Auto)
  in
  match choice with
  | Some Ai_provider_anthropic.Convert_tools.Tc_auto -> ()
  | _ -> fail "expected Tc_auto"

let test_tool_choice_required () =
  let _, choice =
    Ai_provider_anthropic.Convert_tools.convert_tools ~tools:[] ~tool_choice:(Some Ai_provider.Tool_choice.Required)
  in
  match choice with
  | Some Ai_provider_anthropic.Convert_tools.Tc_any -> ()
  | _ -> fail "expected Tc_any"

let test_tool_choice_none () =
  let tools, choice =
    Ai_provider_anthropic.Convert_tools.convert_tools
      ~tools:[ { Ai_provider.Tool.name = "search"; description = None; parameters = `Null } ]
      ~tool_choice:(Some Ai_provider.Tool_choice.None_)
  in
  (check int) "0 tools" 0 (List.length tools);
  (check bool) "no choice" true (Option.is_none choice)

let test_tool_choice_specific () =
  let _, choice =
    Ai_provider_anthropic.Convert_tools.convert_tools ~tools:[]
      ~tool_choice:(Some (Ai_provider.Tool_choice.Specific { tool_name = "foo" }))
  in
  match choice with
  | Some (Ai_provider_anthropic.Convert_tools.Tc_tool { name }) -> (check string) "name" "foo" name
  | _ -> fail "expected Tc_tool"

let test_tool_to_json () =
  let tool : Ai_provider_anthropic.Convert_tools.anthropic_tool =
    {
      name = "search";
      description = Some "Search";
      input_schema = `Assoc [ "type", `String "object" ];
      cache_control = None;
    }
  in
  let json = Ai_provider_anthropic.Convert_tools.anthropic_tool_to_json tool in
  let r = tool_json_of_json json in
  (check string) "name" "search" r.name

let test_empty_tools () =
  let tools, choice = Ai_provider_anthropic.Convert_tools.convert_tools ~tools:[] ~tool_choice:None in
  (check int) "0 tools" 0 (List.length tools);
  (check bool) "auto" true (Option.is_some choice)

let () =
  run "Convert_tools"
    [
      ( "convert",
        [
          test_case "single_tool" `Quick test_single_tool;
          test_case "auto" `Quick test_tool_choice_auto;
          test_case "required" `Quick test_tool_choice_required;
          test_case "none" `Quick test_tool_choice_none;
          test_case "specific" `Quick test_tool_choice_specific;
          test_case "empty" `Quick test_empty_tools;
        ] );
      "json", [ test_case "tool_to_json" `Quick test_tool_to_json ];
    ]
