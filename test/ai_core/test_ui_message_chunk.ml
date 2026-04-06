open Alcotest

let json_str chunk = Ai_core.Ui_message_chunk.to_json chunk |> Yojson.Basic.to_string

(* Message lifecycle *)
let test_start () =
  let json = json_str (Start { message_id = Some "msg_1"; message_metadata = None }) in
  (check string) "start" {|{"type":"start","messageId":"msg_1"}|} json

let test_start_no_id () =
  let json = json_str (Start { message_id = None; message_metadata = None }) in
  (check string) "start no id" {|{"type":"start"}|} json

let test_finish () =
  let json = json_str (Finish { finish_reason = Some Ai_provider.Finish_reason.Stop; message_metadata = None }) in
  (check string) "finish" {|{"type":"finish","finishReason":"stop"}|} json

let test_finish_no_reason () =
  let json = json_str (Finish { finish_reason = None; message_metadata = None }) in
  (check string) "finish no reason" {|{"type":"finish"}|} json

let test_abort () =
  let json = json_str (Abort { reason = Some "user cancelled" }) in
  (check string) "abort" {|{"type":"abort","reason":"user cancelled"}|} json

(* Step boundaries *)
let test_start_step () =
  let json = json_str Start_step in
  (check string) "start-step" {|{"type":"start-step"}|} json

let test_finish_step () =
  let json = json_str Finish_step in
  (check string) "finish-step" {|{"type":"finish-step"}|} json

(* Text streaming *)
let test_text_start () =
  let json = json_str (Text_start { id = "txt_1" }) in
  (check string) "text-start" {|{"type":"text-start","id":"txt_1"}|} json

let test_text_delta () =
  let json = json_str (Text_delta { id = "txt_1"; delta = "Hello" }) in
  (check string) "text-delta" {|{"type":"text-delta","id":"txt_1","delta":"Hello"}|} json

let test_text_end () =
  let json = json_str (Text_end { id = "txt_1" }) in
  (check string) "text-end" {|{"type":"text-end","id":"txt_1"}|} json

(* Reasoning *)
let test_reasoning_delta () =
  let json = json_str (Reasoning_delta { id = "rsn_1"; delta = "Let me think..." }) in
  (check string) "reasoning-delta" {|{"type":"reasoning-delta","id":"rsn_1","delta":"Let me think..."}|} json

(* Tool interaction *)
let test_tool_input_start () =
  let json = json_str (Tool_input_start { tool_call_id = "tc_1"; tool_name = "search" }) in
  (check string) "tool-input-start" {|{"type":"tool-input-start","toolCallId":"tc_1","toolName":"search"}|} json

let test_tool_input_delta () =
  let json = json_str (Tool_input_delta { tool_call_id = "tc_1"; input_text_delta = {|{"q":|} }) in
  (check string) "tool-input-delta" {|{"type":"tool-input-delta","toolCallId":"tc_1","inputTextDelta":"{\"q\":"}|} json

let test_tool_input_available () =
  let json =
    json_str
      (Tool_input_available { tool_call_id = "tc_1"; tool_name = "search"; input = `Assoc [ "query", `String "test" ] })
  in
  (check string) "tool-input-available"
    {|{"type":"tool-input-available","toolCallId":"tc_1","toolName":"search","input":{"query":"test"}}|} json

let test_tool_output_available () =
  let json =
    json_str (Tool_output_available { tool_call_id = "tc_1"; output = `Assoc [ "result", `String "found" ] })
  in
  (check string) "tool-output-available"
    {|{"type":"tool-output-available","toolCallId":"tc_1","output":{"result":"found"}}|} json

let test_tool_output_error () =
  let json = json_str (Tool_output_error { tool_call_id = "tc_1"; error_text = "not found" }) in
  (check string) "tool-output-error" {|{"type":"tool-output-error","toolCallId":"tc_1","errorText":"not found"}|} json

(* Error *)
let test_error () =
  let json = json_str (Error { error_text = "Something went wrong" }) in
  (check string) "error" {|{"type":"error","errorText":"Something went wrong"}|} json

(* Source *)
let test_source_url () =
  let json = json_str (Source_url { source_id = "src_1"; url = "https://example.com"; title = Some "Example" }) in
  (check string) "source-url" {|{"type":"source-url","sourceId":"src_1","url":"https://example.com","title":"Example"}|}
    json

(* File *)
let test_file () =
  let json = json_str (File { url = "https://example.com/img.png"; media_type = "image/png" }) in
  (check string) "file" {|{"type":"file","url":"https://example.com/img.png","mediaType":"image/png"}|} json

(* Custom data *)
let test_data () =
  let json = json_str (Data { data_type = "message"; id = Some "d_1"; data = `Assoc [ "content", `String "hi" ] }) in
  (check string) "data" {|{"type":"data-message","id":"d_1","data":{"content":"hi"}}|} json

(* V6 extras *)
let test_message_metadata () =
  let json = json_str (Message_metadata { message_metadata = `Assoc [ "key", `String "value" ] }) in
  (check string) "message-metadata" {|{"type":"message-metadata","messageMetadata":{"key":"value"}}|} json

let test_tool_input_error () =
  let json =
    json_str
      (Tool_input_error
         {
           tool_call_id = "tc_1";
           tool_name = "search";
           input = `Assoc [ "q", `String "test" ];
           error_text = "Invalid input";
         })
  in
  (check string) "tool-input-error"
    {|{"type":"tool-input-error","toolCallId":"tc_1","toolName":"search","input":{"q":"test"},"errorText":"Invalid input"}|}
    json

let test_tool_output_denied () =
  let json = json_str (Tool_output_denied { tool_call_id = "tc_1" }) in
  (check string) "tool-output-denied" {|{"type":"tool-output-denied","toolCallId":"tc_1"}|} json

let test_tool_approval_request () =
  let json = json_str (Tool_approval_request { approval_id = "appr_1"; tool_call_id = "tc_1" }) in
  (check string) "tool-approval-request" {|{"type":"tool-approval-request","approvalId":"appr_1","toolCallId":"tc_1"}|}
    json

let test_source_document () =
  let json =
    json_str
      (Source_document
         { source_id = "src_1"; media_type = "application/pdf"; title = "Report"; filename = Some "report.pdf" })
  in
  (check string) "source-document"
    {|{"type":"source-document","sourceId":"src_1","mediaType":"application/pdf","title":"Report","filename":"report.pdf"}|}
    json

let test_source_document_no_filename () =
  let json =
    json_str (Source_document { source_id = "src_2"; media_type = "text/plain"; title = "Notes"; filename = None })
  in
  (check string) "source-document no filename"
    {|{"type":"source-document","sourceId":"src_2","mediaType":"text/plain","title":"Notes"}|} json

let () =
  run "Ui_message_chunk"
    [
      ( "lifecycle",
        [
          test_case "start" `Quick test_start;
          test_case "start_no_id" `Quick test_start_no_id;
          test_case "finish" `Quick test_finish;
          test_case "finish_no_reason" `Quick test_finish_no_reason;
          test_case "abort" `Quick test_abort;
        ] );
      "steps", [ test_case "start_step" `Quick test_start_step; test_case "finish_step" `Quick test_finish_step ];
      ( "text",
        [
          test_case "text_start" `Quick test_text_start;
          test_case "text_delta" `Quick test_text_delta;
          test_case "text_end" `Quick test_text_end;
        ] );
      "reasoning", [ test_case "reasoning_delta" `Quick test_reasoning_delta ];
      ( "tools",
        [
          test_case "input_start" `Quick test_tool_input_start;
          test_case "input_delta" `Quick test_tool_input_delta;
          test_case "input_available" `Quick test_tool_input_available;
          test_case "output_available" `Quick test_tool_output_available;
          test_case "output_error" `Quick test_tool_output_error;
        ] );
      ( "other",
        [
          test_case "error" `Quick test_error;
          test_case "source_url" `Quick test_source_url;
          test_case "file" `Quick test_file;
          test_case "data" `Quick test_data;
        ] );
      ( "v6_extras",
        [
          test_case "message_metadata" `Quick test_message_metadata;
          test_case "tool_input_error" `Quick test_tool_input_error;
          test_case "tool_output_denied" `Quick test_tool_output_denied;
          test_case "tool_approval_request" `Quick test_tool_approval_request;
          test_case "source_document" `Quick test_source_document;
          test_case "source_document_no_filename" `Quick test_source_document_no_filename;
        ] );
    ]
