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

let test_execute_exception () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~execute:(fun _writer -> Lwt.fail (Failure "execute blew up"))
      ()
  in
  let chunks = collect stream in
  (* Start + Error + Finish *)
  (check int) "3 chunks" 3 (List.length chunks);
  (match List.nth chunks 1 with
   | Ai_core.Ui_message_chunk.Error { error_text } ->
     (check bool) "contains error message" true (String.length error_text > 0)
   | _ -> fail "expected Error chunk");
  (match List.nth chunks 2 with
   | Ai_core.Ui_message_chunk.Finish _ -> ()
   | _ -> fail "expected Finish")

let test_custom_on_error () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~on_error:(fun _exn -> "custom error message")
      ~execute:(fun _writer -> Lwt.fail (Failure "boom"))
      ()
  in
  let chunks = collect stream in
  (match List.nth chunks 1 with
   | Ai_core.Ui_message_chunk.Error { error_text = "custom error message" } -> ()
   | _ -> fail "expected custom error message")

let test_on_finish_normal () =
  let finish_called = ref false in
  let was_aborted = ref false in
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~on_finish:(fun ~finish_reason:_ ~is_aborted ->
        finish_called := true;
        was_aborted := is_aborted;
        Lwt.return_unit)
      ~execute:(fun writer ->
        Ai_core.Ui_message_stream_writer.write writer
          (Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "hi" });
        Lwt.return_unit)
      ()
  in
  let _chunks = collect stream in
  (check bool) "on_finish called" true !finish_called;
  (check bool) "not aborted" false !was_aborted

let test_on_finish_aborted () =
  let finish_called = ref false in
  let was_aborted = ref false in
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~on_finish:(fun ~finish_reason:_ ~is_aborted ->
        finish_called := true;
        was_aborted := is_aborted;
        Lwt.return_unit)
      ~execute:(fun _writer -> Lwt.fail (Failure "crash"))
      ()
  in
  let _chunks = collect stream in
  (check bool) "on_finish called" true !finish_called;
  (check bool) "aborted" true !was_aborted

let test_on_finish_waits_for_merges () =
  let merge_completed = ref false in
  let finish_saw_merge_done = ref false in
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~on_finish:(fun ~finish_reason:_ ~is_aborted:_ ->
        finish_saw_merge_done := !merge_completed;
        Lwt.return_unit)
      ~execute:(fun writer ->
        let source =
          Lwt_stream.from (fun () ->
            if not !merge_completed then begin
              merge_completed := true;
              Lwt.return_some (Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "x" })
            end else
              Lwt.return_none)
        in
        Ai_core.Ui_message_stream_writer.merge writer source;
        Lwt.return_unit)
      ()
  in
  let _chunks = collect stream in
  (check bool) "merge completed before on_finish" true !finish_saw_merge_done

let test_response_headers () =
  let chunks_stream, push = Lwt_stream.create () in
  push (Some (Ai_core.Ui_message_chunk.Start { message_id = None; message_metadata = None }));
  push (Some (Ai_core.Ui_message_chunk.Finish { finish_reason = None; message_metadata = None }));
  push None;
  let response, _body =
    Lwt_main.run (Ai_core.Ui_message_stream_writer.create_ui_message_stream_response chunks_stream)
  in
  let headers = Cohttp.Response.headers response in
  (* Check SSE headers *)
  (check (option string)) "content-type"
    (Some "text/event-stream")
    (Cohttp.Header.get headers "content-type");
  (* Check CORS headers (default cors=true) *)
  (check (option string)) "cors origin"
    (Some "*")
    (Cohttp.Header.get headers "access-control-allow-origin");
  (* Check protocol header *)
  (check (option string)) "protocol"
    (Some "v1")
    (Cohttp.Header.get headers "x-vercel-ai-ui-message-stream")

let test_response_no_cors () =
  let chunks_stream, push = Lwt_stream.create () in
  push (Some (Ai_core.Ui_message_chunk.Start { message_id = None; message_metadata = None }));
  push None;
  let response, _body =
    Lwt_main.run (Ai_core.Ui_message_stream_writer.create_ui_message_stream_response ~cors:false chunks_stream)
  in
  let headers = Cohttp.Response.headers response in
  (check (option string)) "no cors"
    None
    (Cohttp.Header.get headers "access-control-allow-origin")

let test_response_custom_status () =
  let chunks_stream, push = Lwt_stream.create () in
  push None;
  let response, _body =
    Lwt_main.run
      (Ai_core.Ui_message_stream_writer.create_ui_message_stream_response
         ~status:`Created chunks_stream)
  in
  (check int) "status 201" 201 (Cohttp.Code.code_of_status (Cohttp.Response.status response))

let test_response_body_is_sse () =
  let chunks_stream, push = Lwt_stream.create () in
  push (Some (Ai_core.Ui_message_chunk.Start { message_id = None; message_metadata = None }));
  push (Some (Ai_core.Ui_message_chunk.Finish { finish_reason = None; message_metadata = None }));
  push None;
  let _response, body =
    Lwt_main.run (Ai_core.Ui_message_stream_writer.create_ui_message_stream_response chunks_stream)
  in
  let body_str = Lwt_main.run (Cohttp_lwt.Body.to_string body) in
  (* Should contain SSE data lines *)
  (check bool) "contains data:" true (String.length body_str > 0);
  (* Should end with DONE *)
  (check bool) "ends with DONE"
    true
    (let done_marker = "data: [DONE]\n\n" in
     let len = String.length body_str in
     let dlen = String.length done_marker in
     len >= dlen && String.sub body_str (len - dlen) dlen = done_marker)

let test_persistence_pattern () =
  (* Simulate: server generates a message ID for persistence *)
  let generated_id = "msg_" ^ string_of_int (Random.int 100000) in
  let persisted_id = ref None in
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~message_id:generated_id
      ~on_finish:(fun ~finish_reason:_ ~is_aborted:_ ->
        (* In real code: save message to database using generated_id *)
        persisted_id := Some generated_id;
        Lwt.return_unit)
      ~execute:(fun writer ->
        Ai_core.Ui_message_stream_writer.write writer
          (Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "response text" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (* The Start chunk carries the message ID for the frontend *)
  (match List.nth chunks 0 with
   | Ai_core.Ui_message_chunk.Start { message_id = Some id; _ } ->
     (check string) "start has message_id" generated_id id
   | _ -> fail "expected Start with message_id");
  (* on_finish was called, so persistence happened *)
  (check (option string)) "persisted" (Some generated_id) !persisted_id

let test_merge_already_closed_stream () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~execute:(fun writer ->
        (* Source stream is already closed *)
        let source, source_push = Lwt_stream.create () in
        source_push None;
        Ai_core.Ui_message_stream_writer.merge writer source;
        Lwt_unix.sleep 0.01)
      ()
  in
  let chunks = collect stream in
  (* Start + Finish only — empty merge contributes nothing *)
  (check int) "2 chunks" 2 (List.length chunks);
  (match List.nth chunks 0 with
   | Ai_core.Ui_message_chunk.Start _ -> ()
   | _ -> fail "expected Start");
  (match List.nth chunks 1 with
   | Ai_core.Ui_message_chunk.Finish _ -> ()
   | _ -> fail "expected Finish")

let test_multiple_concurrent_merges () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~execute:(fun writer ->
        (* Create two source streams *)
        let source1, push1 = Lwt_stream.create () in
        push1 (Some (Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "from-1" }));
        push1 None;
        let source2, push2 = Lwt_stream.create () in
        push2 (Some (Ai_core.Ui_message_chunk.Text_delta { id = "t2"; delta = "from-2" }));
        push2 None;
        Ai_core.Ui_message_stream_writer.merge writer source1;
        Ai_core.Ui_message_stream_writer.merge writer source2;
        Lwt_unix.sleep 0.01)
      ()
  in
  let chunks = collect stream in
  (* Start + 2 deltas (from both merges) + Finish = at least 4 *)
  (check bool) "at least 4 chunks" true (List.length chunks >= 4);
  (* Both deltas should be present (order may vary) *)
  let deltas =
    List.filter_map
      (function
        | Ai_core.Ui_message_chunk.Text_delta { delta; _ } -> Some delta
        | _ -> None)
      chunks
  in
  (check int) "2 deltas" 2 (List.length deltas);
  (check bool) "has from-1" true (List.mem "from-1" deltas);
  (check bool) "has from-2" true (List.mem "from-2" deltas);
  (* Should start with Start and end with Finish *)
  (match List.nth chunks 0 with
   | Ai_core.Ui_message_chunk.Start _ -> ()
   | _ -> fail "expected Start");
  (match List.nth chunks (List.length chunks - 1) with
   | Ai_core.Ui_message_chunk.Finish _ -> ()
   | _ -> fail "expected Finish")

let test_on_finish_exception_still_closes_stream () =
  let stream =
    Ai_core.Ui_message_stream_writer.create_ui_message_stream
      ~on_finish:(fun ~finish_reason:_ ~is_aborted:_ ->
        Lwt.fail (Failure "on_finish exploded"))
      ~execute:(fun writer ->
        Ai_core.Ui_message_stream_writer.write writer
          (Ai_core.Ui_message_chunk.Text_delta { id = "t1"; delta = "hi" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (* Stream should still close properly despite on_finish failing *)
  (check bool) "stream closed" true (List.length chunks >= 2);
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
      ( "error_handling",
        [
          test_case "execute exception" `Quick test_execute_exception;
          test_case "custom on_error" `Quick test_custom_on_error;
        ] );
      ( "on_finish",
        [
          test_case "normal completion" `Quick test_on_finish_normal;
          test_case "aborted on error" `Quick test_on_finish_aborted;
          test_case "waits for merges" `Quick test_on_finish_waits_for_merges;
        ] );
      ( "response",
        [
          test_case "headers with cors" `Quick test_response_headers;
          test_case "no cors" `Quick test_response_no_cors;
          test_case "custom status" `Quick test_response_custom_status;
          test_case "body is sse" `Quick test_response_body_is_sse;
        ] );
      ( "usage_patterns",
        [
          test_case "persistence with message_id" `Quick test_persistence_pattern;
        ] );
      ( "edge_cases",
        [
          test_case "merge already closed stream" `Quick test_merge_already_closed_stream;
          test_case "multiple concurrent merges" `Quick test_multiple_concurrent_merges;
          test_case "on_finish exception still closes stream" `Quick test_on_finish_exception_still_closes_stream;
        ] );
    ]
