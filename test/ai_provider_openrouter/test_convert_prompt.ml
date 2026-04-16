open Alcotest

let json_field key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let test_convert_system_message () =
  let messages =
    Ai_provider_openrouter.Convert_prompt.convert_messages ~system_message_mode:System
      [ Ai_provider.Prompt.System { content = "You are helpful" } ]
  in
  let msgs, warnings = messages in
  (check int) "one message" 1 (List.length msgs);
  (check int) "no warnings" 0 (List.length warnings);
  match msgs with
  | [ msg ] ->
    let json = Ai_provider_openrouter.Convert_prompt.openai_message_to_json msg in
    (match json_field "role" json with
    | Some (`String role) -> (check string) "role" "system" role
    | _ -> fail "expected role field");
    (match json_field "content" json with
    | Some (`String content) -> (check string) "content" "You are helpful" content
    | _ -> fail "expected content field")
  | _ -> fail "expected exactly one message"

let test_convert_user_message () =
  let messages =
    Ai_provider_openrouter.Convert_prompt.convert_messages ~system_message_mode:System
      [ Ai_provider.Prompt.User { content = [ Text { text = "Hello"; provider_options = [] } ] } ]
  in
  let msgs, _ = messages in
  (check int) "one message" 1 (List.length msgs);
  match msgs with
  | [ msg ] ->
    let json = Ai_provider_openrouter.Convert_prompt.openai_message_to_json msg in
    (match json_field "role" json with
    | Some (`String role) -> (check string) "role" "user" role
    | _ -> fail "expected role field")
  | _ -> fail "expected exactly one message"

let () =
  run "Convert_prompt"
    [
      ( "convert_prompt",
        [
          test_case "system_message" `Quick test_convert_system_message;
          test_case "user_message" `Quick test_convert_user_message;
        ] );
    ]
