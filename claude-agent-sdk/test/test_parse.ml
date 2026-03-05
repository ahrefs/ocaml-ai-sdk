open Claude_agent_sdk

(* Test helpers *)

let check_ok msg = function
  | Ok v -> v
  | Error e -> Alcotest.fail (msg ^ ": " ^ e)

(* Content block parsing *)

let test_text_block () =
  let json = Yojson.Safe.from_string {|{"type":"text","text":"hello world"}|} in
  let block = check_ok "text_block" (Types.content_block_of_yojson json) in
  match block with
  | Types.Text { text } -> Alcotest.(check string) "text content" "hello world" text
  | _ -> Alcotest.fail "expected Text block"

let test_thinking_block () =
  let json = Yojson.Safe.from_string {|{"type":"thinking","thinking":"let me think","signature":"sig123"}|} in
  let block = check_ok "thinking_block" (Types.content_block_of_yojson json) in
  match block with
  | Types.Thinking { thinking; signature } ->
    Alcotest.(check string) "thinking" "let me think" thinking;
    Alcotest.(check string) "signature" "sig123" signature
  | _ -> Alcotest.fail "expected Thinking block"

let test_tool_use_block () =
  let json = Yojson.Safe.from_string {|{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}|} in
  let block = check_ok "tool_use_block" (Types.content_block_of_yojson json) in
  match block with
  | Types.Tool_use { id; name; input } ->
    Alcotest.(check string) "id" "tu_1" id;
    Alcotest.(check string) "name" "Bash" name;
    let cmd = Yojson.Safe.Util.(member "command" input |> to_string) in
    Alcotest.(check string) "input.command" "ls" cmd
  | _ -> Alcotest.fail "expected Tool_use block"

let test_tool_result_block () =
  let json =
    Yojson.Safe.from_string {|{"type":"tool_result","tool_use_id":"tu_1","content":"output","is_error":false}|}
  in
  let block = check_ok "tool_result_block" (Types.content_block_of_yojson json) in
  match block with
  | Types.Tool_result { tool_use_id; content; is_error } ->
    Alcotest.(check string) "tool_use_id" "tu_1" tool_use_id;
    Alcotest.(check string) "content" "output" content;
    Alcotest.(check bool) "is_error" false is_error
  | _ -> Alcotest.fail "expected Tool_result block"

let test_unknown_content_block () =
  let json = Yojson.Safe.from_string {|{"type":"unknown_type","data":123}|} in
  match Types.content_block_of_yojson json with
  | Error _ -> () (* expected *)
  | Ok _ -> Alcotest.fail "expected error for unknown type"

(* Usage parsing *)

let test_usage () =
  let json =
    Yojson.Safe.from_string
      {|{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10,"cache_creation_input_tokens":5,"extra_field":"ignored"}|}
  in
  let usage = check_ok "usage" (Types.usage_of_yojson json) in
  Alcotest.(check int) "input_tokens" 100 usage.input_tokens;
  Alcotest.(check int) "output_tokens" 50 usage.output_tokens;
  Alcotest.(check int) "cache_read" 10 usage.cache_read_input_tokens;
  Alcotest.(check int) "cache_creation" 5 usage.cache_creation_input_tokens

let test_usage_defaults () =
  let json = Yojson.Safe.from_string {|{}|} in
  let usage = check_ok "usage_defaults" (Types.usage_of_yojson json) in
  Alcotest.(check int) "input_tokens" 0 usage.input_tokens;
  Alcotest.(check int) "output_tokens" 0 usage.output_tokens

(* Message parsing *)

let test_system_message () =
  let json =
    Yojson.Safe.from_string
      {|{"type":"system","subtype":"init","cwd":"/tmp","session_id":"sess-1","tools":["Bash","Glob"],"model":"claude-sonnet-4-5-20250929","permissionMode":"bypassPermissions","uuid":"uuid-1","extra":"ignored"}|}
  in
  let msg = Message.of_json json in
  match msg with
  | Message.System s ->
    Alcotest.(check string) "subtype" "init" s.subtype;
    Alcotest.(check (option string)) "session_id" (Some "sess-1") s.session_id;
    Alcotest.(check (option string)) "cwd" (Some "/tmp") s.cwd;
    Alcotest.(check (list string)) "tools" [ "Bash"; "Glob" ] s.tools;
    Alcotest.(check (option string)) "model" (Some "claude-sonnet-4-5-20250929") s.model;
    Alcotest.(check (option string)) "permission_mode" (Some "bypassPermissions") s.permission_mode
  | _ -> Alcotest.fail "expected System message"

let test_assistant_message () =
  let json =
    Yojson.Safe.from_string
      {|{"type":"assistant","message":{"id":"msg_1","model":"claude-sonnet-4-5-20250929","role":"assistant","content":[{"type":"text","text":"hello"}],"stop_reason":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-1","uuid":"uuid-2"}|}
  in
  let msg = Message.of_json json in
  match msg with
  | Message.Assistant a ->
    Alcotest.(check string) "id" "msg_1" a.message.id;
    Alcotest.(check string) "role" "assistant" a.message.role;
    Alcotest.(check int) "content length" 1 (List.length a.message.content);
    (match List.hd a.message.content with
    | Types.Text { text } -> Alcotest.(check string) "text" "hello" text
    | _ -> Alcotest.fail "expected Text content");
    Alcotest.(check (option string)) "session_id" (Some "sess-1") a.session_id
  | _ -> Alcotest.fail "expected Assistant message"

let test_result_message () =
  let json =
    Yojson.Safe.from_string
      {|{"type":"result","subtype":"success","is_error":false,"duration_ms":2087,"duration_api_ms":1838,"num_turns":1,"result":"hello","session_id":"sess-1","total_cost_usd":0.021}|}
  in
  let msg = Message.of_json json in
  match msg with
  | Message.Result r ->
    Alcotest.(check string) "subtype" "success" r.subtype;
    Alcotest.(check bool) "is_error" false r.is_error;
    Alcotest.(check (option string)) "result" (Some "hello") r.result;
    Alcotest.(check (option (float 0.0001))) "cost" (Some 0.021) r.total_cost_usd;
    Alcotest.(check (option int)) "num_turns" (Some 1) r.num_turns
  | _ -> Alcotest.fail "expected Result message"

let test_unknown_message () =
  let json = Yojson.Safe.from_string {|{"type":"future_type","data":"something"}|} in
  match Message.of_json json with
  | Message.Unknown _ -> ()
  | _ -> Alcotest.fail "expected Unknown message"

let test_missing_type () =
  let json = Yojson.Safe.from_string {|{"data":"no type field"}|} in
  match Message.of_json json with
  | Message.Unknown _ -> ()
  | _ -> Alcotest.fail "expected Unknown message"

(* Message convenience functions *)

let test_is_result () =
  let json = Yojson.Safe.from_string {|{"type":"result","subtype":"success","is_error":false,"result":"ok"}|} in
  let msg = Message.of_json json in
  Alcotest.(check bool) "is_result" true (Message.is_result msg)

let test_result_text () =
  let json = Yojson.Safe.from_string {|{"type":"result","subtype":"success","is_error":false,"result":"hello"}|} in
  let msg = Message.of_json json in
  Alcotest.(check (option string)) "result_text" (Some "hello") (Message.result_text msg)

let test_assistant_text () =
  let json =
    Yojson.Safe.from_string
      {|{"type":"assistant","message":{"id":"msg_1","model":"m","role":"assistant","content":[{"type":"text","text":"hello "},{"type":"text","text":"world"}],"stop_reason":null,"usage":{}}}|}
  in
  let msg = Message.of_json json in
  Alcotest.(check (option string)) "assistant_text" (Some "hello world") (Message.assistant_text msg)

let test_session_id_extraction () =
  let json = Yojson.Safe.from_string {|{"type":"system","subtype":"init","session_id":"sess-42"}|} in
  let msg = Message.of_json json in
  Alcotest.(check (option string)) "session_id" (Some "sess-42") (Message.session_id msg)

(* Content block roundtrip *)

let test_content_block_roundtrip () =
  let block = Types.Text { text = "hello" } in
  let json = Types.content_block_to_yojson block in
  let block' = check_ok "roundtrip" (Types.content_block_of_yojson json) in
  match block' with
  | Types.Text { text } -> Alcotest.(check string) "roundtrip text" "hello" text
  | _ -> Alcotest.fail "roundtrip failed"

(* Options *)

let test_permission_mode_to_string () =
  Alcotest.(check string) "default" "default" (Options.permission_mode_to_string Options.Default);
  Alcotest.(check string) "acceptEdits" "acceptEdits" (Options.permission_mode_to_string Options.Accept_edits);
  Alcotest.(check string) "plan" "plan" (Options.permission_mode_to_string Options.Plan);
  Alcotest.(check string) "bypass" "bypassPermissions" (Options.permission_mode_to_string Options.Bypass_permissions)

(* Test suite *)

let () =
  Alcotest.run "claude-agent-sdk"
    [
      ( "content_blocks",
        [
          Alcotest.test_case "text" `Quick test_text_block;
          Alcotest.test_case "thinking" `Quick test_thinking_block;
          Alcotest.test_case "tool_use" `Quick test_tool_use_block;
          Alcotest.test_case "tool_result" `Quick test_tool_result_block;
          Alcotest.test_case "unknown" `Quick test_unknown_content_block;
          Alcotest.test_case "roundtrip" `Quick test_content_block_roundtrip;
        ] );
      "usage", [ Alcotest.test_case "full" `Quick test_usage; Alcotest.test_case "defaults" `Quick test_usage_defaults ];
      ( "messages",
        [
          Alcotest.test_case "system" `Quick test_system_message;
          Alcotest.test_case "assistant" `Quick test_assistant_message;
          Alcotest.test_case "result" `Quick test_result_message;
          Alcotest.test_case "unknown type" `Quick test_unknown_message;
          Alcotest.test_case "missing type" `Quick test_missing_type;
        ] );
      ( "convenience",
        [
          Alcotest.test_case "is_result" `Quick test_is_result;
          Alcotest.test_case "result_text" `Quick test_result_text;
          Alcotest.test_case "assistant_text" `Quick test_assistant_text;
          Alcotest.test_case "session_id" `Quick test_session_id_extraction;
        ] );
      "options", [ Alcotest.test_case "permission_mode" `Quick test_permission_mode_to_string ];
    ]
