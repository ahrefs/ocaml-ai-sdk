open Alcotest

let test_convert_single_tool () =
  let tool =
    { Ai_provider.Tool.name = "get_weather"; description = Some "Get weather"; parameters = `Assoc [] }
  in
  let converted = Ai_provider_openrouter.Convert_tools.convert_tools ~strict:true [ tool ] in
  (check int) "one tool" 1 (List.length converted);
  (match converted with
  | [ t ] ->
    let json = Ai_provider_openrouter.Convert_tools.openai_tool_to_json t in
    let json_str = Yojson.Basic.to_string json in
    (check bool) "contains function type" true (String.length json_str > 0)
  | _ -> fail "expected exactly one tool")

let test_convert_tool_choice_auto () =
  let json = Ai_provider_openrouter.Convert_tools.convert_tool_choice Auto in
  (check string) "auto" {|"auto"|} (Yojson.Basic.to_string json)

let test_convert_tool_choice_required () =
  let json = Ai_provider_openrouter.Convert_tools.convert_tool_choice Required in
  (check string) "required" {|"required"|} (Yojson.Basic.to_string json)

let test_convert_tool_choice_none () =
  let json = Ai_provider_openrouter.Convert_tools.convert_tool_choice None_ in
  (check string) "none" {|"none"|} (Yojson.Basic.to_string json)

let () =
  run "Convert_tools"
    [
      ( "convert_tools",
        [
          test_case "single_tool" `Quick test_convert_single_tool;
          test_case "tool_choice_auto" `Quick test_convert_tool_choice_auto;
          test_case "tool_choice_required" `Quick test_convert_tool_choice_required;
          test_case "tool_choice_none" `Quick test_convert_tool_choice_none;
        ] );
    ]
