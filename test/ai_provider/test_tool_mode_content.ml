open Alcotest

(* Tool tests *)
let test_tool () =
  let t : Ai_provider.Tool.t =
    { name = "search"; description = Some "Search the web"; parameters = `Assoc [ "type", `String "object" ] }
  in
  (check string) "name" "search" t.name;
  (check (option string)) "description" (Some "Search the web") t.description

(* Tool_choice tests *)
let test_tool_choice_auto () =
  let _c : Ai_provider.Tool_choice.t = Auto in
  ()

let test_tool_choice_required () =
  let _c : Ai_provider.Tool_choice.t = Required in
  ()

let test_tool_choice_none () =
  let _c : Ai_provider.Tool_choice.t = None_ in
  ()

let test_tool_choice_specific () =
  let c : Ai_provider.Tool_choice.t = Specific { tool_name = "search" } in
  match c with
  | Ai_provider.Tool_choice.Specific { tool_name } -> (check string) "tool_name" "search" tool_name
  | Ai_provider.Tool_choice.Auto | Ai_provider.Tool_choice.Required | Ai_provider.Tool_choice.None_ ->
    fail "expected Specific"

(* Mode tests *)
let test_mode_regular () =
  let _m : Ai_provider.Mode.t = Regular in
  ()

let test_mode_object_json_none () =
  let _m : Ai_provider.Mode.t = Object_json None in
  ()

let test_mode_object_json_schema () =
  let schema : Ai_provider.Mode.json_schema = { name = "response"; schema = `Assoc [ "type", `String "object" ] } in
  let _m : Ai_provider.Mode.t = Object_json (Some schema) in
  ()

let test_mode_object_tool () =
  let schema : Ai_provider.Mode.json_schema = { name = "output"; schema = `Assoc [ "type", `String "object" ] } in
  let _m : Ai_provider.Mode.t = Object_tool { tool_name = "json"; schema } in
  ()

(* Content tests *)
let test_content_text () =
  let c : Ai_provider.Content.t = Text { text = "hello" } in
  match c with
  | Ai_provider.Content.Text { text } -> (check string) "text" "hello" text
  | _ -> fail "expected Text"

let test_content_tool_call () =
  let c : Ai_provider.Content.t =
    Tool_call { tool_call_type = "function"; tool_call_id = "tc_1"; tool_name = "search"; args = {|{"query":"test"}|} }
  in
  match c with
  | Ai_provider.Content.Tool_call { tool_call_id; tool_name; _ } ->
    (check string) "id" "tc_1" tool_call_id;
    (check string) "name" "search" tool_name
  | Ai_provider.Content.Text _ | Ai_provider.Content.Reasoning _ | Ai_provider.Content.File _ ->
    fail "expected Tool_call"

let test_content_reasoning () =
  let c : Ai_provider.Content.t =
    Reasoning
      { text = "Let me think..."; signature = Some "sig123"; provider_options = Ai_provider.Provider_options.empty }
  in
  match c with
  | Ai_provider.Content.Reasoning { text; signature; _ } ->
    (check string) "text" "Let me think..." text;
    (check (option string)) "sig" (Some "sig123") signature
  | Ai_provider.Content.Text _ | Ai_provider.Content.Tool_call _ | Ai_provider.Content.File _ ->
    fail "expected Reasoning"

let () =
  run "Tool_Mode_Content"
    [
      "tool", [ test_case "construction" `Quick test_tool ];
      ( "tool_choice",
        [
          test_case "auto" `Quick test_tool_choice_auto;
          test_case "required" `Quick test_tool_choice_required;
          test_case "none" `Quick test_tool_choice_none;
          test_case "specific" `Quick test_tool_choice_specific;
        ] );
      ( "mode",
        [
          test_case "regular" `Quick test_mode_regular;
          test_case "object_json_none" `Quick test_mode_object_json_none;
          test_case "object_json_schema" `Quick test_mode_object_json_schema;
          test_case "object_tool" `Quick test_mode_object_tool;
        ] );
      ( "content",
        [
          test_case "text" `Quick test_content_text;
          test_case "tool_call" `Quick test_content_tool_call;
          test_case "reasoning" `Quick test_content_reasoning;
        ] );
    ]
