open Alcotest

(* SSE encoding tests *)

let test_chunk_to_sse_text_delta () =
  let chunk = Ai_core.Ui_message_chunk.Text_delta { id = "txt_1"; delta = "Hello" } in
  let sse = Ai_core.Ui_message_stream.chunk_to_sse chunk in
  (check string) "sse format" "data: {\"type\":\"text-delta\",\"id\":\"txt_1\",\"delta\":\"Hello\"}\n\n" sse

let test_chunk_to_sse_start () =
  let chunk = Ai_core.Ui_message_chunk.Start { message_id = Some "msg_1"; message_metadata = None } in
  let sse = Ai_core.Ui_message_stream.chunk_to_sse chunk in
  (check string) "sse start" "data: {\"type\":\"start\",\"messageId\":\"msg_1\"}\n\n" sse

let test_done_sse () = (check string) "done" "data: [DONE]\n\n" Ai_core.Ui_message_stream.done_sse

let test_headers () =
  let hdrs = Ai_core.Ui_message_stream.headers in
  let content_type = List.assoc "content-type" hdrs in
  (check string) "content-type" "text/event-stream" content_type;
  let proto = List.assoc "x-vercel-ai-ui-message-stream" hdrs in
  (check string) "protocol version" "v1" proto

let test_stream_to_sse () =
  let chunks_stream, push = Lwt_stream.create () in
  push (Some (Ai_core.Ui_message_chunk.Start { message_id = Some "msg_1"; message_metadata = None }));
  push (Some (Ai_core.Ui_message_chunk.Text_start { id = "txt_1" }));
  push (Some (Ai_core.Ui_message_chunk.Text_delta { id = "txt_1"; delta = "Hi" }));
  push (Some (Ai_core.Ui_message_chunk.Text_end { id = "txt_1" }));
  push
    (Some
       (Ai_core.Ui_message_chunk.Finish { finish_reason = Some Ai_provider.Finish_reason.Stop; message_metadata = None }));
  push None;
  let sse_stream = Ai_core.Ui_message_stream.stream_to_sse chunks_stream in
  let lines = Lwt_main.run (Lwt_stream.to_list sse_stream) in
  (* 5 chunks + 1 DONE = 6 SSE messages *)
  (check int) "6 sse messages" 6 (List.length lines);
  (* First should be start *)
  let first = List.nth lines 0 in
  (check bool) "starts with data:" true (String.length first > 6 && String.sub first 0 6 = "data: ");
  (* Last should be DONE *)
  let last = List.nth lines 5 in
  (check string) "ends with DONE" "data: [DONE]\n\n" last

let test_stream_to_sse_empty () =
  let chunks_stream, push = Lwt_stream.create () in
  push None;
  let sse_stream = Ai_core.Ui_message_stream.stream_to_sse chunks_stream in
  let lines = Lwt_main.run (Lwt_stream.to_list sse_stream) in
  (* Just the DONE message *)
  (check int) "1 sse message" 1 (List.length lines);
  (check string) "DONE" "data: [DONE]\n\n" (List.nth lines 0)

let () =
  run "Ui_message_stream"
    [
      ( "sse_encoding",
        [
          test_case "text_delta" `Quick test_chunk_to_sse_text_delta;
          test_case "start" `Quick test_chunk_to_sse_start;
          test_case "done" `Quick test_done_sse;
        ] );
      "headers", [ test_case "headers" `Quick test_headers ];
      ( "stream",
        [
          test_case "stream_to_sse" `Quick test_stream_to_sse;
          test_case "empty_stream" `Quick test_stream_to_sse_empty;
        ] );
    ]
