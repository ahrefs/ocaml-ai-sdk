open Alcotest
module Mock = Ai_mock.Language_model
module Model = Ai_provider.Language_model

(* Call options whose prompt is one system message, so a recorded call can be
   told apart by [prompt_text]. *)
let options ?abort_signal text =
  {
    (Ai_provider.Call_options.default
       ~prompt:[ System { content = text; provider_options = Ai_provider.Provider_options.empty } ])
    with
    abort_signal;
  }

let prompt_text (options : Ai_provider.Call_options.t) =
  match options.prompt with
  | [ System { content; _ } ] -> content
  | _ -> fail "expected a single system message"

let text_of (result : Ai_provider.Generate_result.t) =
  match result.content with
  | [ Text { text } ] -> text
  | _ -> fail "expected a single text part"

let text_result text = Mock.generate_result [ Text { text } ]

let part_name : Ai_provider.Stream_part.t -> string = function
  | Stream_start _ -> "stream-start"
  | Text { text } -> "text:" ^ text
  | Reasoning _ -> "reasoning"
  | Tool_call_delta _ -> "tool-call-delta"
  | Tool_call_finish _ -> "tool-call-finish"
  | File _ -> "file"
  | Source _ -> "source"
  | Finish _ -> "finish"
  | Error _ -> "error"

let parts =
  [
    Ai_provider.Stream_part.Stream_start { warnings = [] };
    Text { text = "Hi" };
    Finish
      {
        finish_reason = Stop;
        usage = { input_tokens = 1; output_tokens = 1; total_tokens = Some 2 };
        provider_metadata = None;
      };
  ]

let stream_names model options =
  let%lwt { Ai_provider.Stream_result.stream; _ } = Model.stream model options in
  let%lwt parts = Lwt_stream.to_list stream in
  Lwt.return (List.map part_name parts)

(* Gives [promise] a few scheduler turns, then reports whether it is still
   pending. *)
let is_pending promise =
  let%lwt () = Lwt.pause () in
  let%lwt () = Lwt.pause () in
  Lwt.return
    (match Lwt.state promise with
    | Sleep -> true
    | Return _ | Fail _ -> false)

let expect_failure ~what promise =
  match%lwt promise with
  | (_ : Ai_provider.Generate_result.t) -> failf "%s: expected a failure" what
  | exception Failure (_ : string) -> Lwt.return_unit

let test_defaults () =
  let model, (_ : Mock.t) = Mock.create () in
  (check string) "provider" "mock-provider" (Model.provider model);
  (check string) "model id" "mock-model-id" (Model.model_id model);
  let model, (_ : Mock.t) = Mock.create ~provider:"p" ~model_id:"m" () in
  (check string) "custom provider" "p" (Model.provider model);
  (check string) "custom model id" "m" (Model.model_id model)

let test_not_implemented () =
  Lwt_main.run
    (let model, mock = Mock.create () in
     let%lwt () = expect_failure ~what:"generate" (Model.generate model (options "a")) in
     let%lwt () =
       match%lwt Model.stream model (options "b") with
       | (_ : Ai_provider.Stream_result.t) -> fail "stream: expected a failure"
       | exception Failure (_ : string) -> Lwt.return_unit
     in
     (check int) "generate call recorded" 1 (List.length (Mock.generate_calls mock));
     (check int) "stream call recorded" 1 (List.length (Mock.stream_calls mock));
     Lwt.return_unit)

let test_return () =
  Lwt_main.run
    (let model, (_ : Mock.t) = Mock.create ~generate:(Return (text_result "same")) () in
     let%lwt first = Model.generate model (options "a") in
     let%lwt second = Model.generate model (options "b") in
     (check (list string)) "every call" [ "same"; "same" ] [ text_of first; text_of second ];
     Lwt.return_unit)

let test_generate_result_defaults () =
  let result = Mock.generate_result [] in
  (check string) "finish reason" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  (check int) "input tokens" 0 result.usage.input_tokens;
  (check int) "output tokens" 0 result.usage.output_tokens

let test_sequence () =
  Lwt_main.run
    (let model, (_ : Mock.t) = Mock.create ~generate:(Sequence [ text_result "one"; text_result "two" ]) () in
     let%lwt first = Model.generate model (options "a") in
     let%lwt second = Model.generate model (options "b") in
     (check (list string)) "in order" [ "one"; "two" ] [ text_of first; text_of second ];
     expect_failure ~what:"third call" (Model.generate model (options "c")))

let test_respond () =
  Lwt_main.run
    (let model, (_ : Mock.t) =
       Mock.create ~generate:(Respond (fun options -> Lwt.return (text_result (prompt_text options)))) ()
     in
     let%lwt result = Model.generate model (options "echo") in
     (check string) "from the options" "echo" (text_of result);
     Lwt.return_unit)

let test_records_calls () =
  Lwt_main.run
    (let model, mock = Mock.create ~generate:(Return (text_result "x")) ~stream:(Return parts) () in
     (check int) "no calls yet" 0 (List.length (Mock.generate_calls mock));
     let%lwt (_ : Ai_provider.Generate_result.t) = Model.generate model (options "first") in
     let%lwt (_ : string list) = stream_names model (options "streamed") in
     let%lwt (_ : Ai_provider.Generate_result.t) = Model.generate model (options "second") in
     (check (list string)) "generate calls" [ "first"; "second" ] (List.map prompt_text (Mock.generate_calls mock));
     (check (list string)) "stream calls" [ "streamed" ] (List.map prompt_text (Mock.stream_calls mock));
     Lwt.return_unit)

let test_stream_parts () =
  Lwt_main.run
    (let model, (_ : Mock.t) = Mock.create ~stream:(Return parts) () in
     let expected = [ "stream-start"; "text:Hi"; "finish" ] in
     let%lwt first = stream_names model (options "a") in
     let%lwt second = stream_names model (options "b") in
     (check (list string)) "first call" expected first;
     (check (list string)) "a fresh stream per call" expected second;
     Lwt.return_unit)

let test_stream_sequence () =
  Lwt_main.run
    (let model, (_ : Mock.t) =
       Mock.create ~stream:(Sequence [ [ Text { text = "one" } ]; [ Text { text = "two" } ] ]) ()
     in
     let%lwt first = stream_names model (options "a") in
     let%lwt second = stream_names model (options "b") in
     (check (list string)) "in order" [ "text:one"; "text:two" ] (first @ second);
     Lwt.return_unit)

let test_hang_aborts () =
  Lwt_main.run
    (let model, (_ : Mock.t) = Mock.create ~generate:(Respond (Mock.hang ())) () in
     let abort_signal, abort = Ai_provider.Abort_signal.create () in
     let call = Model.generate model (options ~abort_signal "a") in
     let%lwt pending = is_pending call in
     (check bool) "pending before the abort" true pending;
     abort ~reason:Exit ();
     match%lwt call with
     | (_ : Ai_provider.Generate_result.t) -> fail "expected Aborted"
     | exception Ai_provider.Abort_signal.Aborted { reason } ->
       (check (option string)) "the signal's reason" (Some "Stdlib.Exit") (Option.map Printexc.to_string reason);
       Lwt.return_unit)

let test_hang_ignores_abort () =
  Lwt_main.run
    (let model, (_ : Mock.t) = Mock.create ~generate:(Respond (Mock.hang ~ignore_abort:true ())) () in
     let abort_signal, abort = Ai_provider.Abort_signal.create () in
     let call = Model.generate model (options ~abort_signal "a") in
     abort ();
     let%lwt pending = is_pending call in
     (check bool) "pending after the abort" true pending;
     Lwt.cancel call;
     let%lwt pending = is_pending call in
     (check bool) "cancelled" false pending;
     Lwt.return_unit)

let test_hang_without_signal () =
  Lwt_main.run
    (let model, (_ : Mock.t) = Mock.create ~generate:(Respond (Mock.hang ())) () in
     let%lwt pending = is_pending (Model.generate model (options "a")) in
     (check bool) "pending" true pending;
     Lwt.return_unit)

let test_hanging_stream () =
  Lwt_main.run
    (let model, (_ : Mock.t) =
       Mock.create ~stream:(Respond (Mock.hanging_stream [ Stream_start { warnings = [] }; Text { text = "Hi" } ])) ()
     in
     let abort_signal, abort = Ai_provider.Abort_signal.create () in
     let%lwt { Ai_provider.Stream_result.stream; _ } = Model.stream model (options ~abort_signal "a") in
     let%lwt sent = Lwt_stream.nget 2 stream in
     (check (list string)) "parts" [ "stream-start"; "text:Hi" ] (List.map part_name sent);
     let next = Lwt_stream.get stream in
     let%lwt pending = is_pending next in
     (check bool) "no further part" true pending;
     abort ();
     match%lwt next with
     | None -> Lwt.return_unit
     | Some part -> failf "expected the end of the stream, got %s" (part_name part))

let test_hanging_stream_ignores_abort () =
  Lwt_main.run
    (let model, (_ : Mock.t) = Mock.create ~stream:(Respond (Mock.hanging_stream ~ignore_abort:true [])) () in
     let abort_signal, abort = Ai_provider.Abort_signal.create () in
     let%lwt { Ai_provider.Stream_result.stream; _ } = Model.stream model (options ~abort_signal "a") in
     abort ();
     let%lwt pending = is_pending (Lwt_stream.get stream) in
     (check bool) "still open" true pending;
     Lwt.return_unit)

let () =
  run "Ai_mock.Language_model"
    [
      ( "generate",
        [
          test_case "defaults" `Quick test_defaults;
          test_case "not implemented" `Quick test_not_implemented;
          test_case "return" `Quick test_return;
          test_case "generate_result defaults" `Quick test_generate_result_defaults;
          test_case "sequence" `Quick test_sequence;
          test_case "respond" `Quick test_respond;
          test_case "records calls" `Quick test_records_calls;
        ] );
      "stream", [ test_case "parts" `Quick test_stream_parts; test_case "sequence" `Quick test_stream_sequence ];
      ( "hang",
        [
          test_case "aborts" `Quick test_hang_aborts;
          test_case "ignores abort" `Quick test_hang_ignores_abort;
          test_case "without a signal" `Quick test_hang_without_signal;
          test_case "stream" `Quick test_hanging_stream;
          test_case "stream ignores abort" `Quick test_hanging_stream_ignores_abort;
        ] );
    ]
