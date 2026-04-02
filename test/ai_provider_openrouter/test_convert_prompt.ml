open Alcotest

let test_convert_system_message () =
  let messages =
    Ai_provider_openrouter.Convert_prompt.convert_messages ~system_message_mode:System
      [ Ai_provider.Prompt.System { content = "You are helpful" } ]
  in
  let msgs, warnings = messages in
  (check int) "one message" 1 (List.length msgs);
  (check int) "no warnings" 0 (List.length warnings);
  (match msgs with
  | [ msg ] ->
    let json = Ai_provider_openrouter.Convert_prompt.openai_message_to_json msg in
    let json_str = Yojson.Basic.to_string json in
    (check bool) "contains system role" true (String.length json_str > 0)
  | _ -> fail "expected exactly one message")

let test_convert_user_message () =
  let messages =
    Ai_provider_openrouter.Convert_prompt.convert_messages ~system_message_mode:System
      [ Ai_provider.Prompt.User { content = [ Text { text = "Hello"; provider_options = [] } ] } ]
  in
  let msgs, _ = messages in
  (check int) "one message" 1 (List.length msgs);
  (match msgs with
  | [ msg ] ->
    let json = Ai_provider_openrouter.Convert_prompt.openai_message_to_json msg in
    let json_str = Yojson.Basic.to_string json in
    (check bool) "contains user content" true (String.length json_str > 0)
  | _ -> fail "expected exactly one message")

let () =
  run "Convert_prompt"
    [
      ( "convert_prompt",
        [
          test_case "system_message" `Quick test_convert_system_message;
          test_case "user_message" `Quick test_convert_user_message;
        ] );
    ]
