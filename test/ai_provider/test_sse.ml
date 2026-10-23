open Alcotest

let run_lwt f () = Lwt_main.run (f ())

let test_parse_events_propagates_upstream_exn () =
  let pending = ref [ Lwt.return_some "data: partial"; Lwt.fail (Failure "simulated upstream error") ] in
  let lines =
    Lwt_stream.from (fun () ->
      match !pending with
      | [] -> Lwt.return_none
      | next :: rest ->
        pending := rest;
        next)
  in
  let events = Ai_provider.Sse.parse_events lines in
  let%lwt () =
    match%lwt Lwt_stream.get events with
    | _ -> fail "expected the upstream exception"
    | exception Failure m ->
      (check string) "propagated message" "simulated upstream error" m;
      Lwt.return_unit
  in
  let%lwt rest = Lwt_stream.to_list events in
  (check int) "partial event dropped" 0 (List.length rest);
  Lwt.return_unit

let () =
  run "Sse"
    [
      ( "exception safety",
        [ test_case "propagates upstream exn" `Quick (run_lwt test_parse_events_propagates_upstream_exn) ] );
    ]
