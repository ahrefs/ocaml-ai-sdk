open Alcotest

(** Helper: collect all chunks from a stream into a list *)
let collect stream = Lwt_main.run (Lwt_stream.to_list stream)

let test_write_single_chunk () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~execute:(fun writer ->
        Ai_core.Ui_message_stream_writer.write writer
          (Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "hello" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (* Start + Text_delta + Finish *)
  (check int) "3 chunks" 3 (List.length chunks);
  (match List.nth chunks 0 with
   | Ai_core.Ui_message_chunk.Start { message_id = None; _ } -> ()
   | _ -> fail "expected Start");
  (match List.nth chunks 1 with
   | Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "hello" } -> ()
   | _ -> fail "expected Text_delta");
  (match List.nth chunks 2 with
   | Ai_core.Ui_message_chunk.Finish { finish_reason = None; _ } -> ()
   | _ -> fail "expected Finish")

let test_write_multiple_chunks () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~execute:(fun writer ->
        let write = Ai_core.Ui_message_stream_writer.write writer in
        write (Ai_core.Ui_message_chunk.Text_start { id = "t1" });
        write (Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "hi" });
        write (Ai_core.Ui_message_chunk.Text_end { id = "t1" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (* Start + 3 text chunks + Finish *)
  (check int) "5 chunks" 5 (List.length chunks)

let test_empty_execute () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~execute:(fun _writer -> Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (* Start + Finish only *)
  (check int) "2 chunks" 2 (List.length chunks);
  (match List.nth chunks 0 with
   | Ai_core.Ui_message_chunk.Start _ -> ()
   | _ -> fail "expected Start");
  (match List.nth chunks 1 with
   | Ai_core.Ui_message_chunk.Finish _ -> ()
   | _ -> fail "expected Finish")

let test_message_id_in_start () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~message_id:"msg_persist_123"
      ~execute:(fun _writer -> Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (match List.nth chunks 0 with
   | Ai_core.Ui_message_chunk.Start { message_id = Some "msg_persist_123"; _ } -> ()
   | _ -> fail "expected Start with message_id")

let test_merge_stream () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~execute:(fun writer ->
        let source, source_push = Lwt_stream.create () in
        source_push (Some (Ai_core.Ui_message_chunk.Text_start { id = "t1" }));
        source_push (Some (Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "merged" }));
        source_push (Some (Ai_core.Ui_message_chunk.Text_end { id = "t1" }));
        source_push None;
        Ai_core.Ui_message_stream_writer.merge writer source;
        (* Give the merge task time to consume *)
        Lwt_unix.sleep 0.01)
      ()
  in
  let chunks = collect stream in
  (* Start + 3 merged text chunks + Finish *)
  (check int) "5 chunks" 5 (List.length chunks);
  (match List.nth chunks 1 with
   | Ai_core.Ui_message_chunk.Text_start { id = "t1" } -> ()
   | _ -> fail "expected merged Text_start")

let test_merge_and_write_interleaved () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~execute:(fun writer ->
        (* Write a custom data chunk first *)
        Ai_core.Ui_message_stream_writer.write writer
          (Ai_core.Ui_message_chunk.Data { data_type = "status"; id = Some "s1"; data = `String "loading" });
        (* Merge an LLM-like stream *)
        let source, source_push = Lwt_stream.create () in
        source_push (Some (Ai_core.Ui_message_chunk.Text_start { id = "t1" }));
        source_push (Some (Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "response" }));
        source_push (Some (Ai_core.Ui_message_chunk.Text_end { id = "t1" }));
        source_push None;
        Ai_core.Ui_message_stream_writer.merge writer source;
        (* Write another custom chunk after merge starts *)
        let%lwt () = Lwt_unix.sleep 0.01 in
        Ai_core.Ui_message_stream_writer.write writer
          (Ai_core.Ui_message_chunk.Data { data_type = "status"; id = Some "s1"; data = `String "done" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (* Start + Data(loading) + 3 text chunks + Data(done) + Finish = 7 *)
  (check int) "7 chunks" 7 (List.length chunks);
  (* First real chunk should be the Data loading *)
  (match List.nth chunks 1 with
   | Ai_core.Ui_message_chunk.Data { data_type = "status"; data = `String "loading"; _ } -> ()
   | _ -> fail "expected Data loading");
  (* Last before Finish should be Data done *)
  (match List.nth chunks 5 with
   | Ai_core.Ui_message_chunk.Data { data_type = "status"; data = `String "done"; _ } -> ()
   | _ -> fail "expected Data done")

let test_merge_error_in_source () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~execute:(fun writer ->
        (* Create a stream that fails on the first pull *)
        let failing_source =
          Lwt_stream.from (fun () ->
            Lwt.fail (Failure "source exploded"))
        in
        Ai_core.Ui_message_stream_writer.merge writer failing_source;
        Lwt_unix.sleep 0.05)
      ()
  in
  let chunks = collect stream in
  (* Should contain an Error chunk from the failing source *)
  let has_error =
    List.exists
      (function
        | Ai_core.Ui_message_chunk.Error { error_text } ->
          String.length error_text > 0
        | _ -> false)
      chunks
  in
  (check bool) "has error chunk" true has_error;
  (* Should still end with Finish — the error doesn't kill the stream *)
  let last = List.nth chunks (List.length chunks - 1) in
  (match last with
   | Ai_core.Ui_message_chunk.Finish _ -> ()
   | _ -> fail "expected Finish as last chunk")

let () =
  run "Ui_message_stream_writer"
    [
      ( "write",
        [
          test_case "single chunk" `Quick test_write_single_chunk;
          test_case "multiple chunks" `Quick test_write_multiple_chunks;
          test_case "empty execute" `Quick test_empty_execute;
          test_case "message_id in start" `Quick test_message_id_in_start;
        ] );
      ( "merge",
        [
          test_case "merge stream" `Quick test_merge_stream;
          test_case "interleaved write and merge" `Quick test_merge_and_write_interleaved;
          test_case "error in merged source" `Quick test_merge_error_in_source;
        ] );
    ]
