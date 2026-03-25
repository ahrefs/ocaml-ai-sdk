open Alcotest

let test_system_message () =
  let msg = Ai_provider.Prompt.System { content = "You are helpful" } in
  match msg with
  | Ai_provider.Prompt.System { content } -> (check string) "content" "You are helpful" content
  | _ -> fail "expected System"

let test_user_text () =
  let part : Ai_provider.Prompt.user_part =
    Text { text = "Hello"; provider_options = Ai_provider.Provider_options.empty }
  in
  match part with
  | Ai_provider.Prompt.Text { text; _ } -> (check string) "text" "Hello" text
  | _ -> fail "expected Text"

let test_user_file () =
  let part : Ai_provider.Prompt.user_part =
    File
      {
        data = Base64 "aGVsbG8=";
        media_type = "image/png";
        filename = Some "test.png";
        provider_options = Ai_provider.Provider_options.empty;
      }
  in
  match part with
  | Ai_provider.Prompt.File { media_type; filename; _ } ->
    (check string) "media_type" "image/png" media_type;
    (check (option string)) "filename" (Some "test.png") filename
  | _ -> fail "expected File"

let test_assistant_reasoning () =
  let part : Ai_provider.Prompt.assistant_part =
    Reasoning { text = "thinking..."; provider_options = Ai_provider.Provider_options.empty }
  in
  match part with
  | Ai_provider.Prompt.Reasoning { text; _ } -> (check string) "reasoning" "thinking..." text
  | _ -> fail "expected Reasoning"

let test_assistant_tool_call () =
  let part : Ai_provider.Prompt.assistant_part =
    Tool_call
      {
        id = "tc_1";
        name = "search";
        args = `Assoc [ "query", `String "test" ];
        provider_options = Ai_provider.Provider_options.empty;
      }
  in
  match part with
  | Ai_provider.Prompt.Tool_call { id; name; _ } ->
    (check string) "id" "tc_1" id;
    (check string) "name" "search" name
  | _ -> fail "expected Tool_call"

let test_tool_result () =
  let msg =
    Ai_provider.Prompt.Tool
      {
        content =
          [
            {
              tool_call_id = "tc_1";
              tool_name = "search";
              result = `String "found it";
              is_error = false;
              content = [ Result_text "found it" ];
              provider_options = Ai_provider.Provider_options.empty;
            };
          ];
      }
  in
  match msg with
  | Ai_provider.Prompt.Tool { content } -> (check int) "results count" 1 (List.length content)
  | _ -> fail "expected Tool"

let test_file_data_variants () =
  let _bytes : Ai_provider.Prompt.file_data = Bytes (Bytes.of_string "data") in
  let _base64 : Ai_provider.Prompt.file_data = Base64 "aGVsbG8=" in
  let _url : Ai_provider.Prompt.file_data = Url "https://example.com/image.png" in
  ()

let () =
  run "Prompt"
    [
      ( "messages",
        [
          test_case "system" `Quick test_system_message;
          test_case "user_text" `Quick test_user_text;
          test_case "user_file" `Quick test_user_file;
          test_case "assistant_reasoning" `Quick test_assistant_reasoning;
          test_case "assistant_tool_call" `Quick test_assistant_tool_call;
          test_case "tool_result" `Quick test_tool_result;
          test_case "file_data_variants" `Quick test_file_data_variants;
        ] );
    ]
