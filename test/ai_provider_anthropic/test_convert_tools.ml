let test_single_tool () =
  let tools : Ai_provider.Tool.t list =
    [ { name = "search"; description = Some "Search the web"; parameters = `Assoc [ "type", `String "object" ] } ]
  in
  let result, choice = Ai_provider_anthropic.Convert_tools.convert_tools ~tools ~tool_choice:None in
  Alcotest.(check int) "1 tool" 1 (List.length result);
  let tool = List.nth result 0 in
  Alcotest.(check string) "name" "search" tool.name;
  Alcotest.(check (option string)) "desc" (Some "Search the web") tool.description;
  Alcotest.(check bool) "auto choice" true (Option.is_some choice)

let test_tool_choice_auto () =
  let _, choice =
    Ai_provider_anthropic.Convert_tools.convert_tools ~tools:[] ~tool_choice:(Some Ai_provider.Tool_choice.Auto)
  in
  match choice with
  | Some Ai_provider_anthropic.Convert_tools.Tc_auto -> ()
  | _ -> Alcotest.fail "expected Tc_auto"

let test_tool_choice_required () =
  let _, choice =
    Ai_provider_anthropic.Convert_tools.convert_tools ~tools:[] ~tool_choice:(Some Ai_provider.Tool_choice.Required)
  in
  match choice with
  | Some Ai_provider_anthropic.Convert_tools.Tc_any -> ()
  | _ -> Alcotest.fail "expected Tc_any"

let test_tool_choice_none () =
  let tools, choice =
    Ai_provider_anthropic.Convert_tools.convert_tools
      ~tools:[ { Ai_provider.Tool.name = "search"; description = None; parameters = `Null } ]
      ~tool_choice:(Some Ai_provider.Tool_choice.None_)
  in
  Alcotest.(check int) "0 tools" 0 (List.length tools);
  Alcotest.(check bool) "no choice" true (Option.is_none choice)

let test_tool_choice_specific () =
  let _, choice =
    Ai_provider_anthropic.Convert_tools.convert_tools ~tools:[]
      ~tool_choice:(Some (Ai_provider.Tool_choice.Specific { tool_name = "foo" }))
  in
  match choice with
  | Some (Ai_provider_anthropic.Convert_tools.Tc_tool { name }) -> Alcotest.(check string) "name" "foo" name
  | _ -> Alcotest.fail "expected Tc_tool"

let test_tool_to_json () =
  let tool : Ai_provider_anthropic.Convert_tools.anthropic_tool =
    {
      name = "search";
      description = Some "Search";
      input_schema = `Assoc [ "type", `String "object" ];
      cache_control = None;
    }
  in
  let json = Ai_provider_anthropic.Convert_tools.anthropic_tool_to_yojson tool in
  let name = Yojson.Safe.Util.(member "name" json |> to_string) in
  Alcotest.(check string) "name" "search" name

let test_empty_tools () =
  let tools, choice = Ai_provider_anthropic.Convert_tools.convert_tools ~tools:[] ~tool_choice:None in
  Alcotest.(check int) "0 tools" 0 (List.length tools);
  Alcotest.(check bool) "auto" true (Option.is_some choice)

let () =
  Alcotest.run "Convert_tools"
    [
      ( "convert",
        [
          Alcotest.test_case "single_tool" `Quick test_single_tool;
          Alcotest.test_case "auto" `Quick test_tool_choice_auto;
          Alcotest.test_case "required" `Quick test_tool_choice_required;
          Alcotest.test_case "none" `Quick test_tool_choice_none;
          Alcotest.test_case "specific" `Quick test_tool_choice_specific;
          Alcotest.test_case "empty" `Quick test_empty_tools;
        ] );
      "json", [ Alcotest.test_case "tool_to_json" `Quick test_tool_to_json ];
    ]
