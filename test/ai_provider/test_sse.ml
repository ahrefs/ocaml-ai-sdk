open Alcotest

let run_lwt f () = Lwt_main.run (f ())

(* When the upstream line stream raises, parse_events must still close its
   output stream so consumers don't hang. *)
let test_parse_events_closes_on_upstream_exn () =
  let raised = ref false in
  let lines =
    Lwt_stream.from (fun () ->
      if !raised then Lwt.return_none
      else (
        raised := true;
        Lwt.fail (Failure "simulated upstream error")))
  in
  (* Set a private async exception hook so the Failure re-raise doesn't
     trip Alcotest's default hook. Install BEFORE parse_events since the
     async thread may start eagerly. *)
  let captured = ref None in
  let prev_hook = !Lwt.async_exception_hook in
  (Lwt.async_exception_hook := fun exn -> captured := Some exn);
  let events = Ai_provider.Sse.parse_events lines in
  let%lwt result = Lwt_stream.to_list events in
  Lwt.async_exception_hook := prev_hook;
  (check int) "no events emitted" 0 (List.length result);
  (match !captured with
  | Some (Failure m) -> (check string) "captured message" "simulated upstream error" m
  | Some e -> fail (Printf.sprintf "unexpected exn: %s" (Printexc.to_string e))
  | None -> fail "expected exception in async hook");
  Lwt.return_unit

let () =
  run "Sse"
    [
      ( "exception safety",
        [ test_case "closes on upstream exn" `Quick (run_lwt test_parse_events_closes_on_upstream_exn) ] );
    ]
