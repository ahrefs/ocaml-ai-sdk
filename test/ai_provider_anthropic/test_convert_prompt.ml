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
      Ai_provider.Prompt.System { content = "You are helpful"; provider_options = Ai_provider.Provider_options.empty };
      Ai_provider.Prompt.User { content = [ Text { text = "Hi"; provider_options = po } ] };
    ]
  in
  let parts, rest = Ai_provider_anthropic.Convert_prompt.extract_system msgs in
  (check int) "1 system part" 1 (List.length parts);
  (check string) "system text" "You are helpful" (fst (List.hd parts));
  (check int) "rest count" 1 (List.length rest)

let test_extract_system_multiple () =
  let msgs =
    [
      Ai_provider.Prompt.System { content = "Part 1"; provider_options = Ai_provider.Provider_options.empty };
      Ai_provider.Prompt.System { content = "Part 2"; provider_options = Ai_provider.Provider_options.empty };
      Ai_provider.Prompt.User { content = [ Text { text = "Hi"; provider_options = po } ] };
    ]
  in
  let parts, rest = Ai_provider_anthropic.Convert_prompt.extract_system msgs in
  (check int) "2 parts" 2 (List.length parts);
  (check int) "rest count" 1 (List.length rest)

let test_extract_system_none () =
  let msgs = [ Ai_provider.Prompt.User { content = [ Text { text = "Hi"; provider_options = po } ] } ] in
  let parts, rest = Ai_provider_anthropic.Convert_prompt.extract_system msgs in
  (check int) "0 parts" 0 (List.length parts);
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

let test_reasoning_with_tool_call_round_trip () =
  let reasoning_options = Ai_provider_anthropic.Convert_response.reasoning_provider_options (Some "sig_roundtrip") in
  let msgs =
    [
      Ai_provider.Prompt.Assistant
        {
          content =
            [
              Ai_provider.Prompt.Reasoning { text = ""; provider_options = reasoning_options };
              Ai_provider.Prompt.Tool_call
                { id = "tc_1"; name = "search"; args = `Assoc [ "query", `String "cats" ]; provider_options = po };
            ];
        };
    ]
  in
  match Ai_provider_anthropic.Convert_prompt.convert_messages msgs with
  | [ { content = [ A_thinking { thinking; signature }; A_tool_use { id; input; _ } ]; _ } ] ->
    (check string) "thinking" "" thinking;
    (check string) "signature" "sig_roundtrip" signature;
    (check string) "tool id" "tc_1" id;
    (check string) "tool input" {|{"query":"cats"}|} (Yojson.Basic.to_string input)
  | _ -> fail "expected thinking and tool-use blocks"

let test_redacted_reasoning_round_trip () =
  let provider_options =
    Ai_provider_anthropic.Convert_response.redacted_reasoning_provider_options "encrypted_reasoning"
  in
  let msgs =
    [ Ai_provider.Prompt.Assistant { content = [ Ai_provider.Prompt.Reasoning { text = ""; provider_options } ] } ]
  in
  match Ai_provider_anthropic.Convert_prompt.convert_messages msgs with
  | [ { content = [ A_redacted_thinking { data } ]; _ } ] ->
    (check string) "redacted data" "encrypted_reasoning" data;
    let json = Ai_provider_anthropic.Convert_prompt.anthropic_content_to_json (A_redacted_thinking { data }) in
    (check string) "wire block" {|{"type":"redacted_thinking","data":"encrypted_reasoning"}|}
      (Yojson.Basic.to_string json)
  | _ -> fail "expected redacted thinking block"

let test_missing_reasoning_signature_rejected () =
  let msgs =
    [
      Ai_provider.Prompt.Assistant
        { content = [ Ai_provider.Prompt.Reasoning { text = "thinking"; provider_options = po } ] };
    ]
  in
  try
    ignore (Ai_provider_anthropic.Convert_prompt.convert_messages msgs);
    fail "expected missing signature to be rejected"
  with Invalid_argument _ -> ()

(* JSON serialization tests *)

let test_text_to_json () =
  let content = Ai_provider_anthropic.Convert_prompt.A_text { text = "hello"; cache_control = None } in
  let json = Ai_provider_anthropic.Convert_prompt.anthropic_content_to_json content in
  let r = content_json_of_json json in
  (check (option string)) "text" (Some "hello") r.text;
  (check string) "type" "text" r.type_

let test_tool_result_cache_control_propagates () =
  let po =
    Ai_provider_anthropic.Cache_control_options.with_cache_control
      ~cache_control:Ai_provider_anthropic.Cache_control.ephemeral Ai_provider.Provider_options.empty
  in
  let msgs =
    [
      Ai_provider.Prompt.Tool
        {
          content =
            [
              {
                tool_call_id = "tc_1";
                tool_name = "search";
                result = `String "found";
                is_error = false;
                content = [ Result_text "found" ];
                provider_options = po;
              };
            ];
        };
    ]
  in
  match Ai_provider_anthropic.Convert_prompt.convert_messages msgs with
  | [ { content = [ A_tool_result { cache_control = Some _; _ } ]; _ } ] -> ()
  | _ -> fail "expected A_tool_result with cache_control set"

(* Upstream @ai-sdk/anthropic always emits the system field as an array of text
   blocks (one per system message). The OCaml provider matches that wire shape
   so the cached and uncached paths stay identical. *)
let test_system_to_json_always_array () =
  match
    Ai_provider_anthropic.Convert_prompt.system_to_json
      [ "A", Ai_provider.Provider_options.empty; "B", Ai_provider.Provider_options.empty ]
  with
  | Some (`List [ `Assoc a; `Assoc b ]) ->
    (check string) "first text" "A" (Yojson.Basic.Util.to_string (List.assoc "text" a));
    (check string) "second text" "B" (Yojson.Basic.Util.to_string (List.assoc "text" b));
    (check bool) "no cache_control without po" true (not (List.mem_assoc "cache_control" a))
  | _ -> fail "expected array-of-blocks form unconditionally"

let test_system_to_json_carries_cache_control () =
  let po =
    Ai_provider_anthropic.Cache_control_options.with_cache_control
      ~cache_control:Ai_provider_anthropic.Cache_control.ephemeral Ai_provider.Provider_options.empty
  in
  match Ai_provider_anthropic.Convert_prompt.system_to_json [ "S", po ] with
  | Some (`List [ `Assoc fields ]) ->
    (check bool) "has cache_control" true (List.mem_assoc "cache_control" fields);
    (check bool) "has text" true (List.mem_assoc "text" fields)
  | _ -> fail "expected array-of-blocks form when cache_control is set"

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
          test_case "to_json_always_array" `Quick test_system_to_json_always_array;
          test_case "to_json_carries_cache_control" `Quick test_system_to_json_carries_cache_control;
        ] );
      ( "convert_messages",
        [
          test_case "user_text" `Quick test_convert_user_text;
          test_case "assistant_text" `Quick test_convert_assistant_text;
          test_case "tool_result" `Quick test_convert_tool_result_as_user;
          test_case "tool_result_cache_control" `Quick test_tool_result_cache_control_propagates;
          test_case "grouping" `Quick test_grouping_consecutive_user;
          test_case "alternating" `Quick test_alternating_preserved;
          test_case "empty" `Quick test_empty_messages;
          test_case "reasoning_tool_round_trip" `Quick test_reasoning_with_tool_call_round_trip;
          test_case "redacted_reasoning_round_trip" `Quick test_redacted_reasoning_round_trip;
          test_case "missing_reasoning_signature" `Quick test_missing_reasoning_signature_rejected;
        ] );
      ( "json",
        [ test_case "text" `Quick test_text_to_json; test_case "text_with_cache" `Quick test_text_with_cache_control ] );
    ]
