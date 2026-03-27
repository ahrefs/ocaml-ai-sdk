open Alcotest

let json_str json = Yojson.Basic.to_string json

let first_exn = function
  | x :: _ -> x
  | [] -> failwith "expected non-empty list"

let test_system_message () =
  let msgs = [ Ai_provider.Prompt.System { content = "You are helpful" } ] in
  let result, warnings = Ai_provider_openai.Convert_prompt.convert_messages ~system_message_mode:System msgs in
  (check int) "warnings" 0 (List.length warnings);
  (check int) "messages" 1 (List.length result);
  let json = Ai_provider_openai.Convert_prompt.openai_message_to_json (first_exn result) in
  (check string) "role" {|"system"|}
    (json_str
       (List.assoc "role"
          (match json with
          | `Assoc l -> l
          | _ -> [])))

let test_developer_message () =
  let msgs = [ Ai_provider.Prompt.System { content = "Instructions" } ] in
  let result, _warnings = Ai_provider_openai.Convert_prompt.convert_messages ~system_message_mode:Developer msgs in
  let json = Ai_provider_openai.Convert_prompt.openai_message_to_json (first_exn result) in
  (check string) "role" {|"developer"|}
    (json_str
       (List.assoc "role"
          (match json with
          | `Assoc l -> l
          | _ -> [])))

let test_remove_system_message () =
  let msgs = [ Ai_provider.Prompt.System { content = "Ignored" } ] in
  let result, warnings = Ai_provider_openai.Convert_prompt.convert_messages ~system_message_mode:Remove msgs in
  (check int) "messages" 0 (List.length result);
  (check int) "warnings" 1 (List.length warnings)

let test_user_text () =
  let msgs =
    [
      Ai_provider.Prompt.User
        { content = [ Text { text = "Hello"; provider_options = Ai_provider.Provider_options.empty } ] };
    ]
  in
  let result, _ = Ai_provider_openai.Convert_prompt.convert_messages ~system_message_mode:System msgs in
  (check int) "messages" 1 (List.length result);
  let json = Ai_provider_openai.Convert_prompt.openai_message_to_json (first_exn result) in
  let json_s = json_str json in
  (check bool) "has content" true (String.length json_s > 0)

let test_user_image () =
  let msgs =
    [
      Ai_provider.Prompt.User
        {
          content =
            [
              File
                {
                  data = Base64 "abc123";
                  media_type = "image/png";
                  filename = None;
                  provider_options = Ai_provider.Provider_options.empty;
                };
            ];
        };
    ]
  in
  let result, _ = Ai_provider_openai.Convert_prompt.convert_messages ~system_message_mode:System msgs in
  let json = Ai_provider_openai.Convert_prompt.openai_message_to_json (first_exn result) in
  let json_s = json_str json in
  (check bool) "has json" true (String.length json_s > 0)

let test_assistant_with_tool_calls () =
  let msgs =
    [
      Ai_provider.Prompt.Assistant
        {
          content =
            [
              Text { text = "Let me help"; provider_options = Ai_provider.Provider_options.empty };
              Tool_call
                {
                  id = "call_1";
                  name = "get_weather";
                  args = `Assoc [ "city", `String "NYC" ];
                  provider_options = Ai_provider.Provider_options.empty;
                };
            ];
        };
    ]
  in
  let result, _ = Ai_provider_openai.Convert_prompt.convert_messages ~system_message_mode:System msgs in
  let json = Ai_provider_openai.Convert_prompt.openai_message_to_json (first_exn result) in
  let fields =
    match json with
    | `Assoc l -> l
    | _ -> []
  in
  (check bool) "has tool_calls" true (List.mem_assoc "tool_calls" fields);
  (check bool) "has content" true (List.mem_assoc "content" fields)

let test_tool_result () =
  let msgs =
    [
      Ai_provider.Prompt.Tool
        {
          content =
            [
              {
                tool_call_id = "call_1";
                tool_name = "get_weather";
                result = `String "Sunny, 72F";
                is_error = false;
                content = [];
                provider_options = Ai_provider.Provider_options.empty;
              };
            ];
        };
    ]
  in
  let result, _ = Ai_provider_openai.Convert_prompt.convert_messages ~system_message_mode:System msgs in
  (check int) "messages" 1 (List.length result);
  let json = Ai_provider_openai.Convert_prompt.openai_message_to_json (first_exn result) in
  let fields =
    match json with
    | `Assoc l -> l
    | _ -> []
  in
  (check string) "role" {|"tool"|} (json_str (List.assoc "role" fields));
  (check string) "tool_call_id" {|"call_1"|} (json_str (List.assoc "tool_call_id" fields))

let () =
  run "Convert_prompt"
    [
      ( "convert_messages",
        [
          test_case "system" `Quick test_system_message;
          test_case "developer" `Quick test_developer_message;
          test_case "remove_system" `Quick test_remove_system_message;
          test_case "user_text" `Quick test_user_text;
          test_case "user_image" `Quick test_user_image;
          test_case "assistant_tool_calls" `Quick test_assistant_with_tool_calls;
          test_case "tool_result" `Quick test_tool_result;
        ] );
    ]
