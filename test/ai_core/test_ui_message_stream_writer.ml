open Alcotest

module Writer = Ai_core.Ui_message_stream_writer
module Chunk = Ai_core.Ui_message_chunk

let collect stream = Lwt_main.run (Lwt_stream.to_list stream)

let assert_framed chunks =
  (match List.nth chunks 0 with
  | Chunk.Start _ -> ()
  | _ -> fail "expected Start as first chunk");
  match List.nth chunks (List.length chunks - 1) with
  | Chunk.Finish _ -> ()
  | _ -> fail "expected Finish as last chunk"

let test_write_single_chunk () =
  let stream =
    Writer.create_ui_message_stream
      ~execute:(fun writer ->
        Writer.write writer (Chunk.Text_delta { id = "t1"; delta = "hello" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (check int) "3 chunks" 3 (List.length chunks);
  (match List.nth chunks 0 with
  | Chunk.Start { message_id = None; _ } -> ()
  | _ -> fail "expected Start");
  (match List.nth chunks 1 with
  | Chunk.Text_delta { id = "t1"; delta = "hello" } -> ()
  | _ -> fail "expected Text_delta");
  match List.nth chunks 2 with
  | Chunk.Finish { finish_reason = None; _ } -> ()
  | _ -> fail "expected Finish"

let test_write_multiple_chunks () =
  let stream =
    Writer.create_ui_message_stream
      ~execute:(fun writer ->
        let write = Writer.write writer in
        write (Chunk.Text_start { id = "t1" });
        write (Chunk.Text_delta { id = "t1"; delta = "hi" });
        write (Chunk.Text_end { id = "t1" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (check int) "5 chunks" 5 (List.length chunks)

let test_empty_execute () =
  let stream = Writer.create_ui_message_stream ~execute:(fun _writer -> Lwt.return_unit) () in
  let chunks = collect stream in
  (check int) "2 chunks" 2 (List.length chunks);
  assert_framed chunks

let test_message_id_in_start () =
  let stream =
    Writer.create_ui_message_stream ~message_id:"msg_persist_123" ~execute:(fun _writer -> Lwt.return_unit) ()
  in
  let chunks = collect stream in
  match List.nth chunks 0 with
  | Chunk.Start { message_id = Some "msg_persist_123"; _ } -> ()
  | _ -> fail "expected Start with message_id"

let test_merge_stream () =
  let stream =
    Writer.create_ui_message_stream
      ~execute:(fun writer ->
        let source, source_push = Lwt_stream.create () in
        source_push (Some (Chunk.Text_start { id = "t1" }));
        source_push (Some (Chunk.Text_delta { id = "t1"; delta = "merged" }));
        source_push (Some (Chunk.Text_end { id = "t1" }));
        source_push None;
        Writer.merge writer source;
        Lwt.pause ())
      ()
  in
  let chunks = collect stream in
  (check int) "5 chunks" 5 (List.length chunks);
  match List.nth chunks 1 with
  | Chunk.Text_start { id = "t1" } -> ()
  | _ -> fail "expected merged Text_start"

let test_merge_and_write_interleaved () =
  let stream =
    Writer.create_ui_message_stream
      ~execute:(fun writer ->
        Writer.write writer (Chunk.Data { data_type = "status"; id = Some "s1"; data = `String "loading" });
        let source, source_push = Lwt_stream.create () in
        source_push (Some (Chunk.Text_start { id = "t1" }));
        source_push (Some (Chunk.Text_delta { id = "t1"; delta = "response" }));
        source_push (Some (Chunk.Text_end { id = "t1" }));
        source_push None;
        Writer.merge writer source;
        let%lwt () = Lwt.pause () in
        Writer.write writer (Chunk.Data { data_type = "status"; id = Some "s1"; data = `String "done" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (check int) "7 chunks" 7 (List.length chunks);
  (match List.nth chunks 1 with
  | Chunk.Data { data_type = "status"; data = `String "loading"; _ } -> ()
  | _ -> fail "expected Data loading");
  match List.nth chunks 5 with
  | Chunk.Data { data_type = "status"; data = `String "done"; _ } -> ()
  | _ -> fail "expected Data done"

let test_merge_error_in_source () =
  let stream =
    Writer.create_ui_message_stream
      ~execute:(fun writer ->
        let failing_source = Lwt_stream.from (fun () -> Lwt.fail (Failure "source exploded")) in
        Writer.merge writer failing_source;
        Lwt.pause ())
      ()
  in
  let chunks = collect stream in
  let has_error =
    List.exists
      (function
        | Chunk.Error { error_text } -> String.length error_text > 0
        | _ -> false)
      chunks
  in
  (check bool) "has error chunk" true has_error;
  assert_framed chunks

let test_execute_exception () =
  let stream = Writer.create_ui_message_stream ~execute:(fun _writer -> Lwt.fail (Failure "execute blew up")) () in
  let chunks = collect stream in
  (check int) "3 chunks" 3 (List.length chunks);
  (match List.nth chunks 1 with
  | Chunk.Error { error_text } -> (check bool) "contains error message" true (String.length error_text > 0)
  | _ -> fail "expected Error chunk");
  match List.nth chunks 2 with
  | Chunk.Finish _ -> ()
  | _ -> fail "expected Finish"

let test_custom_on_error () =
  let stream =
    Writer.create_ui_message_stream
      ~on_error:(fun _exn -> "custom error message")
      ~execute:(fun _writer -> Lwt.fail (Failure "boom"))
      ()
  in
  let chunks = collect stream in
  match List.nth chunks 1 with
  | Chunk.Error { error_text = "custom error message" } -> ()
  | _ -> fail "expected custom error message"

let test_on_finish_normal () =
  let finish_called = ref false in
  let was_aborted = ref false in
  let stream =
    Writer.create_ui_message_stream
      ~on_finish:(fun ~finish_reason:_ ~is_aborted ->
        finish_called := true;
        was_aborted := is_aborted;
        Lwt.return_unit)
      ~execute:(fun writer ->
        Writer.write writer (Chunk.Text_delta { id = "t1"; delta = "hi" });
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
    Writer.create_ui_message_stream
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

(* Runs [execute] and returns the [is_aborted] that [on_finish] received. *)
let finish_is_aborted ~execute =
  let was_aborted = ref None in
  let stream =
    Writer.create_ui_message_stream
      ~on_finish:(fun ~finish_reason:_ ~is_aborted ->
        was_aborted := Some is_aborted;
        Lwt.return_unit)
      ~execute ()
  in
  let (_ : Chunk.t list) = collect stream in
  !was_aborted

let test_on_finish_abort_chunk_written () =
  let is_aborted =
    finish_is_aborted ~execute:(fun writer ->
      Writer.write writer (Chunk.Abort { reason = None });
      Lwt.return_unit)
  in
  (check (option bool)) "aborted" (Some true) is_aborted

let test_on_finish_abort_chunk_merged () =
  let is_aborted =
    finish_is_aborted ~execute:(fun writer ->
      Writer.merge writer (Lwt_stream.of_list [ Chunk.Start_step; Chunk.Abort { reason = None } ]);
      Lwt.return_unit)
  in
  (check (option bool)) "aborted" (Some true) is_aborted

(* The chunk types [execute] leads to, in order. *)
let chunk_types ~execute =
  Writer.create_ui_message_stream ~execute ()
  |> collect
  |> List.map (fun chunk -> Yojson.Basic.Util.(to_string (member "type" (Chunk.to_json chunk))))

(* An aborted stream gets no finish chunk from the writer. *)
let test_abort_chunk_written_no_finish () =
  (check (list string))
    "chunk types" [ "start"; "start-step"; "abort" ]
    (chunk_types ~execute:(fun writer ->
       Writer.write writer Chunk.Start_step;
       Writer.write writer (Chunk.Abort { reason = None });
       Lwt.return_unit))

let test_abort_chunk_merged_no_finish () =
  (check (list string))
    "chunk types" [ "start"; "start-step"; "abort" ]
    (chunk_types ~execute:(fun writer ->
       Writer.merge writer (Lwt_stream.of_list [ Chunk.Start_step; Chunk.Abort { reason = None } ]);
       Lwt.return_unit))

let test_on_finish_waits_for_merges () =
  let merge_completed = ref false in
  let finish_saw_merge_done = ref false in
  let stream =
    Writer.create_ui_message_stream
      ~on_finish:(fun ~finish_reason:_ ~is_aborted:_ ->
        finish_saw_merge_done := !merge_completed;
        Lwt.return_unit)
      ~execute:(fun writer ->
        let source =
          Lwt_stream.from (fun () ->
            if not !merge_completed then begin
              merge_completed := true;
              Lwt.return_some (Chunk.Text_delta { id = "t1"; delta = "x" })
            end
            else Lwt.return_none)
        in
        Writer.merge writer source;
        Lwt.return_unit)
      ()
  in
  let _chunks = collect stream in
  (check bool) "merge completed before on_finish" true !finish_saw_merge_done

let test_response_headers () =
  let chunks_stream, push = Lwt_stream.create () in
  push (Some (Chunk.Start { message_id = None; message_metadata = None }));
  push (Some (Chunk.Finish { finish_reason = None; message_metadata = None }));
  push None;
  let response = Writer.create_ui_message_stream_response chunks_stream in
  let header name = List.assoc_opt name response.headers in
  (check int) "status" 200 response.status;
  (check (option string)) "content-type" (Some "text/event-stream") (header "content-type");
  (check (option string)) "cors origin" (Some "*") (header "access-control-allow-origin");
  (check (option string)) "protocol" (Some "v1") (header "x-vercel-ai-ui-message-stream")

let test_response_no_cors () =
  let chunks_stream, push = Lwt_stream.create () in
  push (Some (Chunk.Start { message_id = None; message_metadata = None }));
  push None;
  let response = Writer.create_ui_message_stream_response ~cors:false chunks_stream in
  (check (option string)) "no cors" None (List.assoc_opt "access-control-allow-origin" response.headers)

let test_response_custom_status () =
  let chunks_stream, push = Lwt_stream.create () in
  push None;
  let response = Writer.create_ui_message_stream_response ~status:201 chunks_stream in
  (check int) "status 201" 201 response.status

let test_response_body_is_sse () =
  let chunks_stream, push = Lwt_stream.create () in
  push (Some (Chunk.Start { message_id = None; message_metadata = None }));
  push (Some (Chunk.Finish { finish_reason = None; message_metadata = None }));
  push None;
  let response = Writer.create_ui_message_stream_response chunks_stream in
  let body_str = String.concat "" (Lwt_main.run (Lwt_stream.to_list response.body)) in
  (check bool) "contains data:" true (String.length body_str > 0);
  (check bool) "ends with DONE" true
    (let done_marker = "data: [DONE]\n\n" in
     let len = String.length body_str in
     let dlen = String.length done_marker in
     len >= dlen && String.sub body_str (len - dlen) dlen = done_marker)

let test_persistence_pattern () =
  let generated_id = "msg_" ^ string_of_int (Random.int 100000) in
  let persisted_id = ref None in
  let stream =
    Writer.create_ui_message_stream ~message_id:generated_id
      ~on_finish:(fun ~finish_reason:_ ~is_aborted:_ ->
        persisted_id := Some generated_id;
        Lwt.return_unit)
      ~execute:(fun writer ->
        Writer.write writer (Chunk.Text_delta { id = "t1"; delta = "response text" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (match List.nth chunks 0 with
  | Chunk.Start { message_id = Some id; _ } -> (check string) "start has message_id" generated_id id
  | _ -> fail "expected Start with message_id");
  (check (option string)) "persisted" (Some generated_id) !persisted_id

let test_merge_already_closed_stream () =
  let stream =
    Writer.create_ui_message_stream
      ~execute:(fun writer ->
        let source, source_push = Lwt_stream.create () in
        source_push None;
        Writer.merge writer source;
        Lwt.pause ())
      ()
  in
  let chunks = collect stream in
  (check int) "2 chunks" 2 (List.length chunks);
  assert_framed chunks

let test_multiple_concurrent_merges () =
  let stream =
    Writer.create_ui_message_stream
      ~execute:(fun writer ->
        let source1, push1 = Lwt_stream.create () in
        push1 (Some (Chunk.Text_delta { id = "t1"; delta = "from-1" }));
        push1 None;
        let source2, push2 = Lwt_stream.create () in
        push2 (Some (Chunk.Text_delta { id = "t2"; delta = "from-2" }));
        push2 None;
        Writer.merge writer source1;
        Writer.merge writer source2;
        Lwt.pause ())
      ()
  in
  let chunks = collect stream in
  (check bool) "at least 4 chunks" true (List.length chunks >= 4);
  let deltas =
    List.filter_map
      (function
        | Chunk.Text_delta { delta; _ } -> Some delta
        | _ -> None)
      chunks
  in
  (check int) "2 deltas" 2 (List.length deltas);
  (check bool) "has from-1" true (List.mem "from-1" deltas);
  (check bool) "has from-2" true (List.mem "from-2" deltas);
  assert_framed chunks

let test_on_finish_exception_still_closes_stream () =
  let stream =
    Writer.create_ui_message_stream
      ~on_finish:(fun ~finish_reason:_ ~is_aborted:_ -> Lwt.fail (Failure "on_finish exploded"))
      ~execute:(fun writer ->
        Writer.write writer (Chunk.Text_delta { id = "t1"; delta = "hi" });
        Lwt.return_unit)
      ()
  in
  let chunks = collect stream in
  (check bool) "stream closed" true (List.length chunks >= 2);
  assert_framed chunks

(* Streams "Hi" and then waits, closing its stream only when the abort signal
   fires, as a provider stream does. *)
let make_waiting_model () =
  Ai_mock.Language_model.(
    fst
      (create
         ~stream:
           (Respond (hanging_stream [ Ai_provider.Stream_part.Stream_start { warnings = [] }; Text { text = "Hi" } ]))
         ()))

let status data = Chunk.Data { data_type = "status"; id = Some "s"; data = `String data }

let chunk_type chunk = Yojson.Basic.Util.(to_string (member "type" (Chunk.to_json chunk)))

(* The examples/custom_stream pattern: [execute] merges a stream_text UI stream
   and then awaits [result.usage], which fails with Aborted once the signal
   fires. The writer must wait for the merge before closing, so the merged
   abort chunk never meets a closed stream. The [Aborted] from [execute] adds
   neither an error chunk nor a second abort chunk. Lwt's default async
   exception hook stays in place: an exception escaping [Lwt.async] would
   exit the test. *)
let test_execute_fails_after_merged_abort () =
  let signal, (_ : unit Lwt.u) = Lwt.task () in
  let finished_aborted = ref None in
  let stream =
    Writer.create_ui_message_stream
      ~on_finish:(fun ~finish_reason:_ ~is_aborted ->
        finished_aborted := Some is_aborted;
        Lwt.return_unit)
      ~execute:(fun writer ->
        Writer.write writer (status "generating");
        let result =
          Ai_core.Stream_text.stream_text ~model:(make_waiting_model ()) ~prompt:"Hello" ~abort_signal:signal ()
        in
        Writer.merge writer (Ai_core.Stream_text_result.to_ui_message_stream result);
        let%lwt (_ : Ai_provider.Usage.t) = result.usage in
        Writer.write writer (status "complete");
        Lwt.return_unit)
      ()
  in
  let rec read_until_text acc =
    match%lwt Lwt_stream.get stream with
    | Some (Chunk.Text_delta _ as chunk) -> Lwt.return (List.rev (chunk :: acc))
    | Some chunk -> read_until_text (chunk :: acc)
    | None -> Lwt.return (List.rev acc)
  in
  let chunks =
    Lwt_main.run
      (let%lwt before = read_until_text [] in
       Lwt.cancel signal;
       let%lwt after = Lwt_unix.with_timeout 5.0 (fun () -> Lwt_stream.to_list stream) in
       (* Leaves time for a late push into the closed stream. *)
       let%lwt () = Lwt_unix.sleep 0.05 in
       Lwt.return (before @ after))
  in
  (check (list string))
    "chunk types"
    [ "start"; "data-status"; "start"; "start-step"; "text-start"; "text-delta"; "abort" ]
    (List.map chunk_type chunks);
  (check (option bool)) "on_finish is_aborted" (Some true) !finished_aborted

(* [execute] raising [Aborted] ends the stream with an abort chunk carrying
   the reason, and no error or finish chunk. *)
let test_execute_aborted () =
  let run reason =
    let finished_aborted = ref None in
    let chunks =
      collect
        (Writer.create_ui_message_stream
           ~on_finish:(fun ~finish_reason:_ ~is_aborted ->
             finished_aborted := Some is_aborted;
             Lwt.return_unit)
           ~execute:(fun writer ->
             Writer.write writer Chunk.Start_step;
             Lwt.fail (Ai_provider.Abort_signal.Aborted { reason }))
           ())
    in
    (check (option bool)) "on_finish is_aborted" (Some true) !finished_aborted;
    match chunks with
    | Chunk.Start _ :: rest -> List.map (fun chunk -> Yojson.Basic.to_string (Chunk.to_json chunk)) rest
    | _ -> fail "expected Start as first chunk"
  in
  (check (list string))
    "with a reason"
    [ {|{"type":"start-step"}|}; {|{"type":"abort","reason":"Stdlib.Exit"}|} ]
    (run (Some Exit));
  (check (list string)) "without a reason" [ {|{"type":"start-step"}|}; {|{"type":"abort"}|} ] (run None)

let error_texts chunks =
  List.filter_map
    (function
      | Chunk.Error { error_text } -> Some error_text
      | _ -> None)
    chunks

let failing_source () = Lwt_stream.from (fun () -> Lwt.fail (Failure "merge secret"))

(* A merged stream's failure goes through [on_error] like one from [execute]. *)
let test_merge_error_uses_on_error () =
  let chunks =
    collect
      (Writer.create_ui_message_stream
         ~on_error:(fun _ -> "sanitized")
         ~execute:(fun writer ->
           Writer.merge writer (failing_source ());
           Lwt.return_unit)
         ())
  in
  (check (list string)) "error text" [ "sanitized" ] (error_texts chunks)

(* An [on_error] that raises must not expose the original exception. *)
let test_on_error_raising () =
  let chunks =
    collect
      (Writer.create_ui_message_stream
         ~on_error:(fun _ -> failwith "formatter broke")
         ~execute:(fun _ -> Lwt.fail (Failure "execute secret"))
         ())
  in
  (check (list string)) "error text" [ "An error occurred." ] (error_texts chunks)

(* A chunk written while [on_finish] runs is dropped instead of landing after
   the finish chunk, and the stream ends only once [on_finish] has returned. *)
let test_write_during_on_finish_dropped () =
  let saved = ref None in
  let finished = ref false in
  let chunks =
    collect
      (Writer.create_ui_message_stream
         ~on_finish:(fun ~finish_reason:_ ~is_aborted:_ ->
           Option.iter (fun writer -> Writer.write writer (status "late")) !saved;
           let%lwt () = Lwt.pause () in
           finished := true;
           Lwt.return_unit)
         ~execute:(fun writer ->
           saved := Some writer;
           Lwt.return_unit)
         ())
  in
  (check (list string)) "chunk types" [ "start"; "finish" ] (List.map chunk_type chunks);
  (check bool) "stream ends after on_finish" true !finished

(* A failing [execute] does not cut short a merge that keeps running: its later
   chunks follow the error chunk, then the finish chunk closes the stream. *)
let test_execute_fails_with_running_merge () =
  let source, push = Lwt_stream.create () in
  let stream =
    Writer.create_ui_message_stream
      ~on_error:(fun _ -> "failed")
      ~execute:(fun writer ->
        Writer.merge writer source;
        push (Some (status "before"));
        let%lwt () = Lwt.pause () in
        Lwt.fail (Failure "execute failed"))
      ()
  in
  let chunks =
    Lwt_main.run
      (let%lwt () = Lwt.pause () in
       let%lwt () = Lwt.pause () in
       push (Some (status "after"));
       push None;
       Lwt_unix.with_timeout 5.0 (fun () -> Lwt_stream.to_list stream))
  in
  (check (list string))
    "chunks"
    [ "start"; "data-status:before"; "error:failed"; "data-status:after"; "finish" ]
    (List.map
       (fun chunk ->
         match chunk with
         | Chunk.Data { data = `String text; _ } -> chunk_type chunk ^ ":" ^ text
         | Chunk.Error { error_text } -> "error:" ^ error_text
         | _ -> chunk_type chunk)
       chunks)

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
          test_case "merge error uses on_error" `Quick test_merge_error_uses_on_error;
          test_case "on_error raising" `Quick test_on_error_raising;
          test_case "execute fails with a running merge" `Quick test_execute_fails_with_running_merge;
        ] );
      ( "on_finish",
        [
          test_case "normal completion" `Quick test_on_finish_normal;
          test_case "aborted on error" `Quick test_on_finish_aborted;
          test_case "aborted on written abort chunk" `Quick test_on_finish_abort_chunk_written;
          test_case "aborted on merged abort chunk" `Quick test_on_finish_abort_chunk_merged;
          test_case "no finish after written abort chunk" `Quick test_abort_chunk_written_no_finish;
          test_case "no finish after merged abort chunk" `Quick test_abort_chunk_merged_no_finish;
          test_case "waits for merges" `Quick test_on_finish_waits_for_merges;
          test_case "execute fails after a merged abort" `Quick test_execute_fails_after_merged_abort;
          test_case "execute raises Aborted" `Quick test_execute_aborted;
        ] );
      ( "response",
        [
          test_case "headers with cors" `Quick test_response_headers;
          test_case "no cors" `Quick test_response_no_cors;
          test_case "custom status" `Quick test_response_custom_status;
          test_case "body is sse" `Quick test_response_body_is_sse;
        ] );
      "usage_patterns", [ test_case "persistence with message_id" `Quick test_persistence_pattern ];
      ( "edge_cases",
        [
          test_case "merge already closed stream" `Quick test_merge_already_closed_stream;
          test_case "multiple concurrent merges" `Quick test_multiple_concurrent_merges;
          test_case "on_finish exception still closes stream" `Quick test_on_finish_exception_still_closes_stream;
          test_case "write during on_finish dropped" `Quick test_write_during_on_finish_dropped;
        ] );
    ]
