open Melange_json.Primitives
open Alcotest

type content_json = {
  type_ : string; [@json.key "type"]
  text : string option; [@json.default None]
  cache_control : cache_control_json option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

and cache_control_json = { cc_type : string [@json.key "type"] } [@@deriving of_json]

let po = Ai_provider.Provider_options.empty

(* extract_system tests *)

let test_extract_system_single () =
  let msgs =
    [
      Ai_provider.Prompt.System { content = "You are helpful" };
      Ai_provider.Prompt.User { content = [ Text { text = "Hi"; provider_options = po } ] };
    ]
  in
  let system, rest = Ai_provider_anthropic.Convert_prompt.extract_system msgs in
  (check (option string)) "system" (Some "You are helpful") system;
  (check int) "rest count" 1 (List.length rest)

let test_extract_system_multiple () =
  let msgs =
    [
      Ai_provider.Prompt.System { content = "Part 1" };
      Ai_provider.Prompt.System { content = "Part 2" };
      Ai_provider.Prompt.User { content = [ Text { text = "Hi"; provider_options = po } ] };
    ]
  in
  let system, rest = Ai_provider_anthropic.Convert_prompt.extract_system msgs in
  (check (option string)) "system" (Some "Part 1\nPart 2") system;
  (check int) "rest count" 1 (List.length rest)

let test_extract_system_none () =
  let msgs = [ Ai_provider.Prompt.User { content = [ Text { text = "Hi"; provider_options = po } ] } ] in
  let system, rest = Ai_provider_anthropic.Convert_prompt.extract_system msgs in
  (check (option string)) "no system" None system;
  (check int) "rest count" 1 (List.length rest)

(* convert_messages tests *)

let test_convert_user_text () =
  let msgs = [ Ai_provider.Prompt.User { content = [ Text { text = "Hello"; provider_options = po } ] } ] in
  let result = Ai_provider_anthropic.Convert_prompt.convert_messages msgs in
  (check int) "1 message" 1 (List.length result);
  let msg =
    match result with
    | m :: _ -> m
    | [] -> failwith "expected non-empty"
  in
  (check string) "role" "user"
    (match msg.role with
    | `User -> "user"
    | `Assistant -> "assistant");
  (check int) "1 content" 1 (List.length msg.content)

let test_convert_assistant_text () =
  let msgs = [ Ai_provider.Prompt.Assistant { content = [ Text { text = "Hi there"; provider_options = po } ] } ] in
  let result = Ai_provider_anthropic.Convert_prompt.convert_messages msgs in
  (check int) "1 message" 1 (List.length result);
  let msg =
    match result with
    | m :: _ -> m
    | [] -> failwith "expected non-empty"
  in
  (check string) "role" "assistant"
    (match msg.role with
    | `User -> "user"
    | `Assistant -> "assistant")

let test_convert_tool_result_as_user () =
  let msgs =
    [
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
                provider_options = po;
              };
            ];
        };
    ]
  in
  let result = Ai_provider_anthropic.Convert_prompt.convert_messages msgs in
  (check int) "1 message" 1 (List.length result);
  let msg =
    match result with
    | m :: _ -> m
    | [] -> failwith "expected non-empty"
  in
  (* Tool results become user messages *)
  (check string) "role" "user"
    (match msg.role with
    | `User -> "user"
    | `Assistant -> "assistant")

let test_grouping_consecutive_user () =
  let msgs =
    [
      Ai_provider.Prompt.User { content = [ Text { text = "First"; provider_options = po } ] };
      Ai_provider.Prompt.User { content = [ Text { text = "Second"; provider_options = po } ] };
    ]
  in
  let result = Ai_provider_anthropic.Convert_prompt.convert_messages msgs in
  (* Should be merged into 1 message *)
  (check int) "1 merged message" 1 (List.length result);
  let msg =
    match result with
    | m :: _ -> m
    | [] -> failwith "expected non-empty"
  in
  (check int) "2 content parts" 2 (List.length msg.content)

let test_alternating_preserved () =
  let msgs =
    [
      Ai_provider.Prompt.User { content = [ Text { text = "Q"; provider_options = po } ] };
      Ai_provider.Prompt.Assistant { content = [ Text { text = "A"; provider_options = po } ] };
      Ai_provider.Prompt.User { content = [ Text { text = "Q2"; provider_options = po } ] };
    ]
  in
  let result = Ai_provider_anthropic.Convert_prompt.convert_messages msgs in
  (check int) "3 messages" 3 (List.length result)

let test_empty_messages () =
  let result = Ai_provider_anthropic.Convert_prompt.convert_messages [] in
  (check int) "0 messages" 0 (List.length result)

(* JSON serialization tests *)

let test_text_to_json () =
  let content = Ai_provider_anthropic.Convert_prompt.A_text { text = "hello"; cache_control = None } in
  let json = Ai_provider_anthropic.Convert_prompt.anthropic_content_to_json content in
  let r = content_json_of_json json in
  (check (option string)) "text" (Some "hello") r.text;
  (check string) "type" "text" r.type_

let test_text_with_cache_control () =
  let cc = Ai_provider_anthropic.Cache_control.ephemeral in
  let content = Ai_provider_anthropic.Convert_prompt.A_text { text = "cached"; cache_control = Some cc } in
  let json = Ai_provider_anthropic.Convert_prompt.anthropic_content_to_json content in
  let r = content_json_of_json json in
  match r.cache_control with
  | None -> fail "expected cache_control"
  | Some cc_r -> (check string) "cache type" "ephemeral" cc_r.cc_type

let () =
  run "Convert_prompt"
    [
      ( "extract_system",
        [
          test_case "single" `Quick test_extract_system_single;
          test_case "multiple" `Quick test_extract_system_multiple;
          test_case "none" `Quick test_extract_system_none;
        ] );
      ( "convert_messages",
        [
          test_case "user_text" `Quick test_convert_user_text;
          test_case "assistant_text" `Quick test_convert_assistant_text;
          test_case "tool_result" `Quick test_convert_tool_result_as_user;
          test_case "grouping" `Quick test_grouping_consecutive_user;
          test_case "alternating" `Quick test_alternating_preserved;
          test_case "empty" `Quick test_empty_messages;
        ] );
      ( "json",
        [ test_case "text" `Quick test_text_to_json; test_case "text_with_cache" `Quick test_text_with_cache_control ] );
    ]
