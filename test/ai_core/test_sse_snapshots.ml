open Alcotest

(** SSE wire format snapshot tests.

    Verify byte-exact SSE output matching the Vercel AI SDK's
    UIMessage stream protocol v1 format. *)

(* Helper: produce complete SSE output from a list of chunks *)
let sse_of_chunks chunks =
  let stream, push = Lwt_stream.create () in
  List.iter (fun c -> push (Some c)) chunks;
  push None;
  let sse_stream = Ai_core.Ui_message_stream.stream_to_sse stream in
  let lines = Lwt_main.run (Lwt_stream.to_list sse_stream) in
  String.concat "" lines

(* === Snapshot: Simple text generation === *)

let test_text_generation_snapshot () =
  let chunks : Ai_core.Ui_message_chunk.t list =
    [
      Start { message_id = Some "msg_1"; message_metadata = None };
      Start_step;
      Text_start { id = "txt_1" };
      Text_delta { id = "txt_1"; delta = "Hello" };
      Text_delta { id = "txt_1"; delta = " world!" };
      Text_end { id = "txt_1" };
      Finish_step;
      Finish { finish_reason = Some Ai_provider.Finish_reason.Stop; message_metadata = None };
    ]
  in
  let expected =
    {|data: {"type":"start","messageId":"msg_1"}

data: {"type":"start-step"}

data: {"type":"text-start","id":"txt_1"}

data: {"type":"text-delta","id":"txt_1","delta":"Hello"}

data: {"type":"text-delta","id":"txt_1","delta":" world!"}

data: {"type":"text-end","id":"txt_1"}

data: {"type":"finish-step"}

data: {"type":"finish","finishReason":"stop"}

data: [DONE]

|}
  in
  let actual = sse_of_chunks chunks in
  (check string) "text generation SSE" expected actual

(* === Snapshot: Reasoning + text === *)

let test_reasoning_snapshot () =
  let chunks : Ai_core.Ui_message_chunk.t list =
    [
      Start { message_id = Some "msg_2"; message_metadata = None };
      Start_step;
      Reasoning_start { id = "rsn_1" };
      Reasoning_delta { id = "rsn_1"; delta = "Let me think..." };
      Reasoning_end { id = "rsn_1" };
      Text_start { id = "txt_1" };
      Text_delta { id = "txt_1"; delta = "The answer is 42." };
      Text_end { id = "txt_1" };
      Finish_step;
      Finish { finish_reason = Some Ai_provider.Finish_reason.Stop; message_metadata = None };
    ]
  in
  let expected =
    {|data: {"type":"start","messageId":"msg_2"}

data: {"type":"start-step"}

data: {"type":"reasoning-start","id":"rsn_1"}

data: {"type":"reasoning-delta","id":"rsn_1","delta":"Let me think..."}

data: {"type":"reasoning-end","id":"rsn_1"}

data: {"type":"text-start","id":"txt_1"}

data: {"type":"text-delta","id":"txt_1","delta":"The answer is 42."}

data: {"type":"text-end","id":"txt_1"}

data: {"type":"finish-step"}

data: {"type":"finish","finishReason":"stop"}

data: [DONE]

|}
  in
  let actual = sse_of_chunks chunks in
  (check string) "reasoning SSE" expected actual

(* === Snapshot: Tool call flow === *)

let test_tool_call_snapshot () =
  let chunks : Ai_core.Ui_message_chunk.t list =
    [
      Start { message_id = Some "msg_3"; message_metadata = None };
      Start_step;
      Text_start { id = "txt_1" };
      Text_delta { id = "txt_1"; delta = "Let me search." };
      Text_end { id = "txt_1" };
      Tool_input_start { tool_call_id = "tc_1"; tool_name = "search" };
      Tool_input_delta { tool_call_id = "tc_1"; input_text_delta = {|{"query":"test"}|} };
      Tool_input_available { tool_call_id = "tc_1"; tool_name = "search"; input = `Assoc [ "query", `String "test" ] };
      Tool_output_available
        { tool_call_id = "tc_1"; output = `Assoc [ "result", `String "found" ]; provider_metadata = None };
      Finish_step;
      Start_step;
      Text_start { id = "txt_2" };
      Text_delta { id = "txt_2"; delta = "I found the answer." };
      Text_end { id = "txt_2" };
      Finish_step;
      Finish { finish_reason = Some Ai_provider.Finish_reason.Stop; message_metadata = None };
    ]
  in
  let expected =
    {|data: {"type":"start","messageId":"msg_3"}

data: {"type":"start-step"}

data: {"type":"text-start","id":"txt_1"}

data: {"type":"text-delta","id":"txt_1","delta":"Let me search."}

data: {"type":"text-end","id":"txt_1"}

data: {"type":"tool-input-start","toolCallId":"tc_1","toolName":"search"}

data: {"type":"tool-input-delta","toolCallId":"tc_1","inputTextDelta":"{\"query\":\"test\"}"}

data: {"type":"tool-input-available","toolCallId":"tc_1","toolName":"search","input":{"query":"test"}}

data: {"type":"tool-output-available","toolCallId":"tc_1","output":{"result":"found"}}

data: {"type":"finish-step"}

data: {"type":"start-step"}

data: {"type":"text-start","id":"txt_2"}

data: {"type":"text-delta","id":"txt_2","delta":"I found the answer."}

data: {"type":"text-end","id":"txt_2"}

data: {"type":"finish-step"}

data: {"type":"finish","finishReason":"stop"}

data: [DONE]

|}
  in
  let actual = sse_of_chunks chunks in
  (check string) "tool call SSE" expected actual

(* === Snapshot: Error === *)

let test_error_snapshot () =
  let chunks : Ai_core.Ui_message_chunk.t list =
    [
      Start { message_id = None; message_metadata = None };
      Error { error_text = "Rate limit exceeded" };
      Finish { finish_reason = Some Ai_provider.Finish_reason.Error; message_metadata = None };
    ]
  in
  let expected =
    {|data: {"type":"start"}

data: {"type":"error","errorText":"Rate limit exceeded"}

data: {"type":"finish","finishReason":"error"}

data: [DONE]

|}
  in
  let actual = sse_of_chunks chunks in
  (check string) "error SSE" expected actual

(* === Snapshot: Tool output error === *)

let test_tool_error_snapshot () =
  let chunks : Ai_core.Ui_message_chunk.t list =
    [
      Start { message_id = Some "msg_4"; message_metadata = None };
      Start_step;
      Tool_input_available
        { tool_call_id = "tc_1"; tool_name = "db_query"; input = `Assoc [ "sql", `String "SELECT *" ] };
      Tool_output_error { tool_call_id = "tc_1"; error_text = "Permission denied"; provider_metadata = None };
      Finish_step;
      Finish { finish_reason = Some Ai_provider.Finish_reason.Stop; message_metadata = None };
    ]
  in
  let expected =
    {|data: {"type":"start","messageId":"msg_4"}

data: {"type":"start-step"}

data: {"type":"tool-input-available","toolCallId":"tc_1","toolName":"db_query","input":{"sql":"SELECT *"}}

data: {"type":"tool-output-error","toolCallId":"tc_1","errorText":"Permission denied"}

data: {"type":"finish-step"}

data: {"type":"finish","finishReason":"stop"}

data: [DONE]

|}
  in
  let actual = sse_of_chunks chunks in
  (check string) "tool error SSE" expected actual

(* === Snapshot: Source URL === *)

let test_source_snapshot () =
  let chunks : Ai_core.Ui_message_chunk.t list =
    [
      Start { message_id = Some "msg_5"; message_metadata = None };
      Start_step;
      Text_start { id = "txt_1" };
      Text_delta { id = "txt_1"; delta = "According to docs..." };
      Text_end { id = "txt_1" };
      Source_url { source_id = "src_1"; url = "https://example.com"; title = Some "Example" };
      Finish_step;
      Finish { finish_reason = Some Ai_provider.Finish_reason.Stop; message_metadata = None };
    ]
  in
  let expected =
    {|data: {"type":"start","messageId":"msg_5"}

data: {"type":"start-step"}

data: {"type":"text-start","id":"txt_1"}

data: {"type":"text-delta","id":"txt_1","delta":"According to docs..."}

data: {"type":"text-end","id":"txt_1"}

data: {"type":"source-url","sourceId":"src_1","url":"https://example.com","title":"Example"}

data: {"type":"finish-step"}

data: {"type":"finish","finishReason":"stop"}

data: [DONE]

|}
  in
  let actual = sse_of_chunks chunks in
  (check string) "source SSE" expected actual

(* === Snapshot: Abort === *)

let test_abort_snapshot () =
  let chunks : Ai_core.Ui_message_chunk.t list =
    [
      Start { message_id = Some "msg_6"; message_metadata = None };
      Start_step;
      Text_start { id = "txt_1" };
      Text_delta { id = "txt_1"; delta = "I was about to say..." };
      Abort { reason = Some "User cancelled" };
    ]
  in
  let expected =
    {|data: {"type":"start","messageId":"msg_6"}

data: {"type":"start-step"}

data: {"type":"text-start","id":"txt_1"}

data: {"type":"text-delta","id":"txt_1","delta":"I was about to say..."}

data: {"type":"abort","reason":"User cancelled"}

data: [DONE]

|}
  in
  let actual = sse_of_chunks chunks in
  (check string) "abort SSE" expected actual

(* === Snapshot: V6 extras === *)

let test_v6_extras_snapshot () =
  let chunks : Ai_core.Ui_message_chunk.t list =
    [
      Start { message_id = Some "msg_7"; message_metadata = None };
      Message_metadata { message_metadata = `Assoc [ "model", `String "claude-sonnet-4-6" ] };
      Start_step;
      Tool_input_start { tool_call_id = "tc_1"; tool_name = "db_query" };
      Tool_input_error
        {
          tool_call_id = "tc_1";
          tool_name = "db_query";
          input = `Assoc [ "sql", `String "DROP TABLE" ];
          error_text = "Dangerous query";
        };
      Tool_output_denied { tool_call_id = "tc_1" };
      Finish_step;
      Start_step;
      Text_start { id = "txt_1" };
      Text_delta { id = "txt_1"; delta = "I cannot run that query." };
      Text_end { id = "txt_1" };
      Source_document
        { source_id = "doc_1"; media_type = "application/pdf"; title = "Policy"; filename = Some "policy.pdf" };
      Finish_step;
      Finish { finish_reason = Some Ai_provider.Finish_reason.Stop; message_metadata = None };
    ]
  in
  let expected =
    {|data: {"type":"start","messageId":"msg_7"}

data: {"type":"message-metadata","messageMetadata":{"model":"claude-sonnet-4-6"}}

data: {"type":"start-step"}

data: {"type":"tool-input-start","toolCallId":"tc_1","toolName":"db_query"}

data: {"type":"tool-input-error","toolCallId":"tc_1","toolName":"db_query","input":{"sql":"DROP TABLE"},"errorText":"Dangerous query"}

data: {"type":"tool-output-denied","toolCallId":"tc_1"}

data: {"type":"finish-step"}

data: {"type":"start-step"}

data: {"type":"text-start","id":"txt_1"}

data: {"type":"text-delta","id":"txt_1","delta":"I cannot run that query."}

data: {"type":"text-end","id":"txt_1"}

data: {"type":"source-document","sourceId":"doc_1","mediaType":"application/pdf","title":"Policy","filename":"policy.pdf"}

data: {"type":"finish-step"}

data: {"type":"finish","finishReason":"stop"}

data: [DONE]

|}
  in
  let actual = sse_of_chunks chunks in
  (check string) "v6 extras SSE" expected actual

let () =
  run "SSE Snapshots"
    [
      ( "wire_format",
        [
          test_case "text_generation" `Quick test_text_generation_snapshot;
          test_case "reasoning" `Quick test_reasoning_snapshot;
          test_case "tool_call" `Quick test_tool_call_snapshot;
          test_case "error" `Quick test_error_snapshot;
          test_case "tool_error" `Quick test_tool_error_snapshot;
          test_case "source" `Quick test_source_snapshot;
          test_case "abort" `Quick test_abort_snapshot;
          test_case "v6_extras" `Quick test_v6_extras_snapshot;
        ] );
    ]
