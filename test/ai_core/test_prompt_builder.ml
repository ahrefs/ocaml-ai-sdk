let test_messages_of_prompt_simple () =
  let msgs = Ai_core.Prompt_builder.messages_of_prompt ~prompt:"Hello" () in
  Alcotest.(check int) "1 message" 1 (List.length msgs);
  match List.nth msgs 0 with
  | Ai_provider.Prompt.User { content } -> Alcotest.(check int) "1 part" 1 (List.length content)
  | _ -> Alcotest.fail "expected User"

let test_messages_of_prompt_with_system () =
  let msgs = Ai_core.Prompt_builder.messages_of_prompt ~system:"Be helpful" ~prompt:"Hello" () in
  Alcotest.(check int) "2 messages" 2 (List.length msgs);
  (match List.nth msgs 0 with
  | Ai_provider.Prompt.System { content } -> Alcotest.(check string) "system" "Be helpful" content
  | _ -> Alcotest.fail "expected System");
  match List.nth msgs 1 with
  | Ai_provider.Prompt.User _ -> ()
  | _ -> Alcotest.fail "expected User"

let test_messages_of_string_messages () =
  let msgs =
    Ai_core.Prompt_builder.messages_of_string_messages
      ~messages:[ "user", "Hello"; "assistant", "Hi there"; "user", "How are you?" ]
      ()
  in
  Alcotest.(check int) "3 messages" 3 (List.length msgs)

let test_append_tool_results () =
  let initial =
    [
      Ai_provider.Prompt.User
        { content = [ Text { text = "Search for cats"; provider_options = Ai_provider.Provider_options.empty } ] };
    ]
  in
  let assistant_content =
    [
      Ai_provider.Content.Text { text = "Let me search." };
      Ai_provider.Content.Tool_call
        { tool_call_type = "function"; tool_call_id = "tc_1"; tool_name = "search"; args = {|{"query":"cats"}|} };
    ]
  in
  let tool_results =
    [
      {
        Ai_core.Generate_text_result.tool_call_id = "tc_1";
        tool_name = "search";
        result = `String "found cats";
        is_error = false;
      };
    ]
  in
  let result =
    Ai_core.Prompt_builder.append_assistant_and_tool_results ~messages:initial ~assistant_content ~tool_results
  in
  Alcotest.(check int) "3 messages" 3 (List.length result);
  (match List.nth result 1 with
  | Ai_provider.Prompt.Assistant { content } -> Alcotest.(check int) "2 parts" 2 (List.length content)
  | _ -> Alcotest.fail "expected Assistant");
  match List.nth result 2 with
  | Ai_provider.Prompt.Tool { content } -> Alcotest.(check int) "1 tool result" 1 (List.length content)
  | _ -> Alcotest.fail "expected Tool"

let test_tools_to_provider () =
  let tools =
    [
      ( "search",
        {
          Ai_core.Core_tool.description = Some "Search the web";
          parameters = `Assoc [ "type", `String "object" ];
          execute = (fun _ -> Lwt.return `Null);
        } );
    ]
  in
  let provider_tools = Ai_core.Prompt_builder.tools_to_provider tools in
  Alcotest.(check int) "1 tool" 1 (List.length provider_tools);
  let t = List.nth provider_tools 0 in
  Alcotest.(check string) "name" "search" t.name;
  Alcotest.(check (option string)) "desc" (Some "Search the web") t.description

let () =
  Alcotest.run "Prompt_builder"
    [
      ( "messages_of_prompt",
        [
          Alcotest.test_case "simple" `Quick test_messages_of_prompt_simple;
          Alcotest.test_case "with_system" `Quick test_messages_of_prompt_with_system;
        ] );
      "string_messages", [ Alcotest.test_case "basic" `Quick test_messages_of_string_messages ];
      "append_tool_results", [ Alcotest.test_case "append" `Quick test_append_tool_results ];
      "tools", [ Alcotest.test_case "to_provider" `Quick test_tools_to_provider ];
    ]
