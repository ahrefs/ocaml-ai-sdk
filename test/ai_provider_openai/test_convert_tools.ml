open Alcotest

let test_single_tool () =
  let tool : Ai_provider.Tool.t =
    { name = "get_weather"; description = Some "Get the weather"; parameters = `Assoc [ "type", `String "object" ] }
  in
  let result = Ai_provider_openai.Convert_tools.convert_tools ~strict:true [ tool ] in
  match result with
  | [ t ] ->
    (check string) "type" "function" t.type_;
    (check string) "name" "get_weather" t.function_.name;
    (check (option string)) "description" (Some "Get the weather") t.function_.description;
    (check (option bool)) "strict" (Some true) t.function_.strict
  | _ -> fail "expected exactly one tool"

let test_strict_false () =
  let tool : Ai_provider.Tool.t = { name = "test"; description = None; parameters = `Assoc [] } in
  let result = Ai_provider_openai.Convert_tools.convert_tools ~strict:false [ tool ] in
  match result with
  | [ t ] -> (check (option bool)) "strict" None t.function_.strict
  | _ -> fail "expected exactly one tool"

let test_tool_choice_auto () =
  let result = Ai_provider_openai.Convert_tools.convert_tool_choice Auto in
  (check string) "auto" {|"auto"|} (Yojson.Basic.to_string result)

let test_tool_choice_required () =
  let result = Ai_provider_openai.Convert_tools.convert_tool_choice Required in
  (check string) "required" {|"required"|} (Yojson.Basic.to_string result)

let test_tool_choice_none () =
  let result = Ai_provider_openai.Convert_tools.convert_tool_choice None_ in
  (check string) "none" {|"none"|} (Yojson.Basic.to_string result)

let test_tool_choice_specific () =
  let result = Ai_provider_openai.Convert_tools.convert_tool_choice (Specific { tool_name = "my_tool" }) in
  let json_s = Yojson.Basic.to_string result in
  (check bool) "has my_tool" true (String.length json_s > 0)

let () =
  run "Convert_tools"
    [
      ( "convert",
        [
          test_case "single_tool" `Quick test_single_tool;
          test_case "strict_false" `Quick test_strict_false;
          test_case "auto" `Quick test_tool_choice_auto;
          test_case "required" `Quick test_tool_choice_required;
          test_case "none" `Quick test_tool_choice_none;
          test_case "specific" `Quick test_tool_choice_specific;
        ] );
    ]
