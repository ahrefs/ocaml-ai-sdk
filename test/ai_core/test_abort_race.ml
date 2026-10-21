open Alcotest

(* [Ai_core] does not export [Abort_race]; tests reach it through dune's
   wrapped name. *)
module Abort_race = Ai_core__Abort_race
module Abort_signal = Ai_provider.Abort_signal

let outcome_name promise =
  match Lwt.state promise with
  | Lwt.Return value -> "ok: " ^ value
  | Lwt.Fail (Abort_signal.Aborted { reason = None }) -> "aborted"
  | Lwt.Fail (Abort_signal.Aborted { reason = Some reason }) -> "aborted: " ^ Printexc.to_string reason
  | Lwt.Fail exn -> Printexc.to_string exn
  | Lwt.Sleep -> "pending"

let test_no_signal () =
  (check string) "runs the work" "ok: value" (outcome_name (Abort_race.race None (fun () -> Lwt.return "value")))

let test_already_settled () =
  let signal, abort = Abort_signal.create () in
  abort ~reason:Exit ();
  let ran = ref false in
  let raced =
    Abort_race.race (Some signal) (fun () ->
      ran := true;
      Lwt.return "value")
  in
  (check string) "fails with the reason" "aborted: Stdlib.Exit" (outcome_name raced);
  (check bool) "work not run" false !ran

(* The work ignores the signal and never returns on its own. *)
let test_signal_first () =
  let signal, abort = Abort_signal.create () in
  let work, (_ : string Lwt.u) = Lwt.task () in
  let raced = Abort_race.race (Some signal) (fun () -> work) in
  (check string) "pending while both are" "pending" (outcome_name raced);
  abort ~reason:Exit ();
  (check string) "fails at once" "aborted: Stdlib.Exit" (outcome_name raced);
  (check bool) "work cancelled" true
    (match Lwt.state work with
    | Lwt.Fail Lwt.Canceled -> true
    | Lwt.Fail _ | Lwt.Return _ | Lwt.Sleep -> false);
  (check (option string))
    "signal keeps its reason" (Some "Stdlib.Exit")
    (Option.map Printexc.to_string (Abort_signal.reason signal))

(* A cancelable signal: [Lwt.pick] on it directly would cancel it when the
   work wins. *)
let test_work_first () =
  let signal, (_ : unit Lwt.u) = Lwt.task () in
  let work, finish_work = Lwt.wait () in
  let raced = Abort_race.race (Some signal) (fun () -> work) in
  Lwt.wakeup_later finish_work "value";
  (check string) "work's value" "ok: value" (outcome_name raced);
  (check bool) "signal still pending" false (Abort_signal.is_aborted signal)

let test_work_fails () =
  let signal, (_ : unit Lwt.u) = Lwt.task () in
  let raising () = raise Not_found in
  (check (list string))
    "failures pass through as promises"
    [ "Not_found"; "Not_found"; "Not_found" ]
    [
      outcome_name (Abort_race.race (Some signal) (fun () -> Lwt.fail Not_found));
      outcome_name (Abort_race.race (Some signal) raising);
      outcome_name (Abort_race.race None raising);
    ];
  (check bool) "signal still pending" false (Abort_signal.is_aborted signal)

let () =
  run "Abort_race"
    [
      ( "race",
        [
          test_case "no signal" `Quick test_no_signal;
          test_case "already settled" `Quick test_already_settled;
          test_case "signal first" `Quick test_signal_first;
          test_case "work first" `Quick test_work_first;
          test_case "work fails" `Quick test_work_fails;
        ] );
    ]
