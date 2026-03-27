open Alcotest

let test_basic () =
  let lines, push = Lwt_stream.create () in
  push (Some "event: message");
  push (Some "data: hello");
  push (Some "");
  push None;
  let events = Ai_provider_openai.Sse.parse_events lines in
  let result = Lwt_main.run (Lwt_stream.to_list events) in
  (check int) "events" 1 (List.length result);
  match result with
  | [ evt ] ->
    (check string) "type" "message" evt.event_type;
    (check string) "data" "hello" evt.data
  | _ -> fail "expected exactly one event"

let test_no_event_type () =
  let lines, push = Lwt_stream.create () in
  push (Some "data: just data");
  push (Some "");
  push None;
  let events = Ai_provider_openai.Sse.parse_events lines in
  let result = Lwt_main.run (Lwt_stream.to_list events) in
  (check int) "events" 1 (List.length result);
  match result with
  | [ evt ] ->
    (check string) "type" "" evt.event_type;
    (check string) "data" "just data" evt.data
  | _ -> fail "expected exactly one event"

let test_done_marker () =
  let lines, push = Lwt_stream.create () in
  push (Some "data: {\"content\":\"hi\"}");
  push (Some "");
  push (Some "data: [DONE]");
  push (Some "");
  push None;
  let events = Ai_provider_openai.Sse.parse_events lines in
  let result = Lwt_main.run (Lwt_stream.to_list events) in
  (check int) "events" 2 (List.length result);
  let last = List.nth result 1 in
  (check string) "done data" "[DONE]" last.data

let test_comment () =
  let lines, push = Lwt_stream.create () in
  push (Some ": this is a comment");
  push (Some "data: real data");
  push (Some "");
  push None;
  let events = Ai_provider_openai.Sse.parse_events lines in
  let result = Lwt_main.run (Lwt_stream.to_list events) in
  (check int) "events" 1 (List.length result)

let () =
  run "SSE"
    [
      ( "parser",
        [
          test_case "basic" `Quick test_basic;
          test_case "no_event_type" `Quick test_no_event_type;
          test_case "done_marker" `Quick test_done_marker;
          test_case "comment" `Quick test_comment;
        ] );
    ]
