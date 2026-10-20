open Alcotest

module Abort_signal = Ai_provider.Abort_signal

let test_is_aborted () =
  let pending, (_ : unit Lwt.u) = Lwt.wait () in
  (check bool) "pending" false (Abort_signal.is_aborted pending);
  (check bool) "resolved" true (Abort_signal.is_aborted Lwt.return_unit);
  (check bool) "failed" true (Abort_signal.is_aborted (Lwt.fail Exit));
  let cancelled, (_ : unit Lwt.u) = Lwt.task () in
  Lwt.cancel cancelled;
  (check bool) "cancelled" true (Abort_signal.is_aborted cancelled)

let test_on_abort_already_settled () =
  let calls = ref 0 in
  let detach = Abort_signal.on_abort Lwt.return_unit (fun () -> incr calls) in
  (check int) "ran at once" 1 !calls;
  detach ();
  (check int) "detach after the run does nothing" 1 !calls

let test_on_abort_deferred () =
  let signal, abort = Lwt.wait () in
  let calls = ref 0 in
  let (_ : unit -> unit) = Abort_signal.on_abort signal (fun () -> incr calls) in
  (check int) "not yet" 0 !calls;
  Lwt.wakeup_later abort ();
  (check int) "ran once on abort" 1 !calls

let test_on_abort_detached () =
  let signal, abort = Lwt.wait () in
  let detached_calls = ref 0 in
  let kept_calls = ref 0 in
  let detach = Abort_signal.on_abort signal (fun () -> incr detached_calls) in
  let (_ : unit -> unit) = Abort_signal.on_abort signal (fun () -> incr kept_calls) in
  detach ();
  detach ();
  (check int) "detaching does not run the callback" 0 !detached_calls;
  Lwt.wakeup_later abort ();
  (check int) "detached callback skipped" 0 !detached_calls;
  (check int) "attached callback ran" 1 !kept_calls

(* The signal is a cancelable task, so a cancel that leaked through the detach
   would settle it. *)
let test_detach_spares_signal () =
  let signal, (_ : unit Lwt.u) = Lwt.task () in
  let detach = Abort_signal.on_abort signal ignore in
  detach ();
  (check bool) "signal still pending" false (Abort_signal.is_aborted signal)

let test_wait_resolves_on_failure () =
  let signal, abort = Lwt.wait () in
  let waiting = Abort_signal.wait signal in
  Lwt.wakeup_later_exn abort Exit;
  (check bool) "resolved" true
    (match Lwt.state waiting with
    | Lwt.Return () -> true
    | Lwt.Fail _ | Lwt.Sleep -> false)

(* The signal is a cancelable task, so a cancel that leaked through [wait]
   would settle it. *)
let test_cancelling_wait_spares_signal () =
  let signal, (_ : unit Lwt.u) = Lwt.task () in
  Lwt.cancel (Abort_signal.wait signal);
  (check bool) "signal still pending" false (Abort_signal.is_aborted signal)

let test_fail_if_aborted () =
  let pending, (_ : unit Lwt.u) = Lwt.wait () in
  let outcome signal =
    match Lwt.state (Abort_signal.fail_if_aborted signal) with
    | Lwt.Return () -> "ok"
    | Lwt.Fail Abort_signal.Aborted -> "aborted"
    | Lwt.Fail exn -> Printexc.to_string exn
    | Lwt.Sleep -> "pending"
  in
  (check (list string))
    "outcomes" [ "ok"; "ok"; "aborted" ]
    [ outcome None; outcome (Some pending); outcome (Some Lwt.return_unit) ]

let () =
  run "Abort_signal"
    [
      ( "abort_signal",
        [
          test_case "is_aborted" `Quick test_is_aborted;
          test_case "on_abort when already settled" `Quick test_on_abort_already_settled;
          test_case "on_abort deferred" `Quick test_on_abort_deferred;
          test_case "on_abort detached" `Quick test_on_abort_detached;
          test_case "detach spares the signal" `Quick test_detach_spares_signal;
          test_case "wait resolves on failure" `Quick test_wait_resolves_on_failure;
          test_case "cancelling wait spares the signal" `Quick test_cancelling_wait_spares_signal;
          test_case "fail_if_aborted" `Quick test_fail_if_aborted;
        ] );
    ]
