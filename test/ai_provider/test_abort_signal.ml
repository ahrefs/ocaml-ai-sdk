open Alcotest

module Abort_signal = Ai_provider.Abort_signal

let reason_name signal =
  match Abort_signal.reason signal with
  | None -> "none"
  | Some exn -> Printexc.to_string exn

let test_is_aborted () =
  let pending, (_ : unit Lwt.u) = Lwt.wait () in
  (check bool) "pending" false (Abort_signal.is_aborted pending);
  (check bool) "resolved" true (Abort_signal.is_aborted Lwt.return_unit);
  (check bool) "failed" true (Abort_signal.is_aborted (Lwt.fail Exit));
  let cancelled, (_ : unit Lwt.u) = Lwt.task () in
  Lwt.cancel cancelled;
  (check bool) "cancelled" true (Abort_signal.is_aborted cancelled)

let test_create_resolves () =
  let signal, abort = Abort_signal.create () in
  (check bool) "pending" false (Abort_signal.is_aborted signal);
  abort ();
  (check bool) "aborted right after the call" true (Abort_signal.is_aborted signal);
  abort ~reason:Exit ();
  (check string) "second call ignored" "none" (reason_name signal)

let test_create_with_reason () =
  let signal, abort = Abort_signal.create () in
  abort ~reason:Exit ();
  (check string) "failed with the reason" "Stdlib.Exit" (reason_name signal);
  abort ~reason:Not_found ();
  abort ();
  (check string) "later calls ignored" "Stdlib.Exit" (reason_name signal)

(* Inside a callback, Lwt may defer the signal's own callbacks, but the signal
   has settled when the abort function returns. *)
let test_create_inside_callback () =
  let signal, abort = Abort_signal.create () in
  let seen_inside = ref false in
  let hook_calls = ref 0 in
  let (_ : unit Lwt.t) = Abort_signal.with_on_abort signal (fun () -> incr hook_calls) (fun () -> fst (Lwt.wait ())) in
  let trigger, wake = Lwt.wait () in
  Lwt.on_success trigger (fun () ->
    abort ();
    seen_inside := Abort_signal.is_aborted signal);
  Lwt.wakeup_later wake ();
  (check bool) "aborted inside the callback" true !seen_inside;
  (check int) "hook ran once" 1 !hook_calls

let test_reason () =
  let pending, (_ : unit Lwt.u) = Lwt.wait () in
  let cancelled, (_ : unit Lwt.u) = Lwt.task () in
  Lwt.cancel cancelled;
  (check (list string))
    "reasons"
    [ "none"; "none"; "Stdlib.Exit"; "none" ]
    (List.map reason_name [ pending; Lwt.return_unit; Lwt.fail Exit; cancelled ])

let test_with_on_abort_already_settled () =
  let calls = ref 0 in
  let result = Abort_signal.with_on_abort Lwt.return_unit (fun () -> incr calls) (fun () -> Lwt.return 1) in
  (check int) "ran at once" 1 !calls;
  (check bool) "work ran" true
    (match Lwt.state result with
    | Lwt.Return 1 -> true
    | Lwt.Return _ | Lwt.Fail _ | Lwt.Sleep -> false)

let test_with_on_abort_during_work () =
  let signal, abort = Abort_signal.create () in
  let calls = ref 0 in
  let (_ : unit Lwt.t) = Abort_signal.with_on_abort signal (fun () -> incr calls) (fun () -> fst (Lwt.wait ())) in
  (check int) "not yet" 0 !calls;
  abort ();
  (check int) "ran once on abort" 1 !calls

(* After [settle_work] settles the work, aborting must not run the hook. *)
let check_detached ~what start_work =
  let signal, abort = Abort_signal.create () in
  let calls = ref 0 in
  let result = start_work (fun work -> Abort_signal.with_on_abort signal (fun () -> incr calls) work) in
  abort ();
  (check int) (what ^ ": hook not run") 0 !calls;
  result

let test_with_on_abort_detaches_on_success () =
  let result = check_detached ~what:"success" (fun run -> run (fun () -> Lwt.return 7)) in
  (check bool) "success kept" true
    (match Lwt.state result with
    | Lwt.Return 7 -> true
    | Lwt.Return _ | Lwt.Fail _ | Lwt.Sleep -> false)

let test_with_on_abort_detaches_on_failure () =
  let result = check_detached ~what:"failure" (fun run -> run (fun () -> Lwt.fail Exit)) in
  (check bool) "failure kept" true
    (match Lwt.state result with
    | Lwt.Fail Exit -> true
    | Lwt.Return () | Lwt.Fail _ | Lwt.Sleep -> false)

let test_with_on_abort_detaches_on_cancel () =
  let result =
    check_detached ~what:"cancel" (fun run ->
      let result = run (fun () -> fst (Lwt.task ())) in
      Lwt.cancel result;
      result)
  in
  (check bool) "cancelled" true
    (match Lwt.state result with
    | Lwt.Fail Lwt.Canceled -> true
    | Lwt.Return () | Lwt.Fail _ | Lwt.Sleep -> false)

(* The signal is a cancelable task, so a cancel that leaked through the detach
   would settle it. *)
let test_with_on_abort_spares_signal () =
  let signal, (_ : unit Lwt.u) = Lwt.task () in
  let (_ : unit Lwt.t) = Abort_signal.with_on_abort signal ignore (fun () -> Lwt.return_unit) in
  (check bool) "signal still pending" false (Abort_signal.is_aborted signal)

let test_with_timeout_fires () =
  let reason =
    Lwt_main.run
      (Abort_signal.with_timeout 0.05 (fun signal ->
         let%lwt () = Abort_signal.wait signal in
         Lwt.return (Abort_signal.reason signal)))
  in
  (check bool) "failed with Timeout" true
    (match reason with
    | Some (Abort_signal.Timeout { after_s }) -> Float.equal after_s 0.05
    | Some _ | None -> false)

(* A timer left running would abort the signal at 0.05 s. *)
let test_with_timeout_releases_timer () =
  let signal = Lwt_main.run (Abort_signal.with_timeout 0.05 Lwt.return) in
  Lwt_main.run (Lwt_unix.sleep 0.15);
  (check bool) "signal still pending" false (Abort_signal.is_aborted signal)

let test_choose_first_reason () =
  let first, (_ : unit Lwt.u) = Lwt.task () in
  let second, abort_second = Lwt.task () in
  let result =
    Abort_signal.choose [ first; second ] (fun signal ->
      let%lwt () = Abort_signal.wait signal in
      Lwt.return (reason_name signal))
  in
  (check bool) "pending before any input aborts" true (Lwt.is_sleeping result);
  Lwt.wakeup_later_exn abort_second Exit;
  (check bool) "took the second input's reason" true
    (match Lwt.state result with
    | Lwt.Return "Stdlib.Exit" -> true
    | Lwt.Return _ | Lwt.Fail _ | Lwt.Sleep -> false);
  (check bool) "first input still pending" true (Lwt.is_sleeping first)

let test_choose_already_aborted () =
  let pending, (_ : unit Lwt.u) = Lwt.task () in
  let reason = ref "not run" in
  let (_ : unit Lwt.t) =
    Abort_signal.choose
      [ pending; Lwt.fail Not_found ]
      (fun signal ->
        reason := reason_name signal;
        Lwt.return_unit)
  in
  (check string) "aborted before f runs" "Not_found" !reason;
  (check bool) "pending input untouched" true (Lwt.is_sleeping pending)

(* Once [f] settles, settling an input no longer reaches the chosen signal, and
   the inputs were neither settled nor cancelled. *)
let test_choose_detaches () =
  let first, abort_first = Lwt.task () in
  let second, (_ : unit Lwt.u) = Lwt.task () in
  let chosen = ref Lwt.return_unit in
  let (_ : unit Lwt.t) =
    Abort_signal.choose [ first; second ] (fun signal ->
      chosen := signal;
      Lwt.return_unit)
  in
  (check (list bool)) "inputs still pending" [ true; true ] (List.map Lwt.is_sleeping [ first; second ]);
  Lwt.wakeup_later abort_first ();
  (check bool) "chosen signal untouched" false (Abort_signal.is_aborted !chosen)

(* Runs [choose [input]] with an [f] that returns at once, and returns a weak
   pointer to the chosen signal. With [~leak:true], [f] also hangs a callback
   on [input] that keeps the chosen signal, as a leftover callback from
   [choose] would. *)
let[@inline never] chosen_signal_after_choose ~leak input =
  let weak = Weak.create 1 in
  let (_ : unit Lwt.t) =
    Abort_signal.choose [ input ] (fun signal ->
      Weak.set weak 0 (Some signal);
      (match leak with
      | true -> Lwt.on_termination input (fun () -> ignore (Sys.opaque_identity signal : unit Lwt.t))
      | false -> ());
      Lwt.return_unit)
  in
  weak

(* [input] stays reachable throughout, so the chosen signal survives a full
   collection only if a callback on [input] still refers to it. The leaking
   run shows the check can see such a callback. *)
let test_choose_releases_callbacks () =
  let input, (_ : unit Lwt.u) = Lwt.wait () in
  let released = chosen_signal_after_choose ~leak:false input in
  let leaked = chosen_signal_after_choose ~leak:true input in
  Gc.full_major ();
  (check bool) "chosen signal collected" false (Weak.check released 0);
  (check bool) "leaking callback keeps it" true (Weak.check leaked 0);
  (check bool) "input still pending" true (Lwt.is_sleeping (Sys.opaque_identity input))

let test_wait_resolves_on_failure () =
  let signal, abort = Abort_signal.create () in
  let waiting = Abort_signal.wait signal in
  abort ~reason:Exit ();
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
    | Lwt.Fail (Abort_signal.Aborted { reason = None }) -> "aborted"
    | Lwt.Fail (Abort_signal.Aborted { reason = Some reason }) -> "aborted: " ^ Printexc.to_string reason
    | Lwt.Fail exn -> Printexc.to_string exn
    | Lwt.Sleep -> "pending"
  in
  (check (list string))
    "outcomes"
    [ "ok"; "ok"; "aborted"; "aborted: Stdlib.Exit" ]
    [ outcome None; outcome (Some pending); outcome (Some Lwt.return_unit); outcome (Some (Lwt.fail Exit)) ]

let test_printer () =
  (check (list string))
    "printed"
    [ "Abort_signal.Aborted"; "Abort_signal.Aborted(Abort_signal.Timeout(1.5s))" ]
    (List.map Printexc.to_string
       [
         Abort_signal.Aborted { reason = None };
         Abort_signal.Aborted { reason = Some (Abort_signal.Timeout { after_s = 1.5 }) };
       ])

let () =
  run "Abort_signal"
    [
      ( "abort_signal",
        [
          test_case "is_aborted" `Quick test_is_aborted;
          test_case "create resolves" `Quick test_create_resolves;
          test_case "create with a reason" `Quick test_create_with_reason;
          test_case "create inside a callback" `Quick test_create_inside_callback;
          test_case "reason" `Quick test_reason;
          test_case "with_on_abort when already settled" `Quick test_with_on_abort_already_settled;
          test_case "with_on_abort during the work" `Quick test_with_on_abort_during_work;
          test_case "with_on_abort detaches on success" `Quick test_with_on_abort_detaches_on_success;
          test_case "with_on_abort detaches on failure" `Quick test_with_on_abort_detaches_on_failure;
          test_case "with_on_abort detaches on cancel" `Quick test_with_on_abort_detaches_on_cancel;
          test_case "with_on_abort spares the signal" `Quick test_with_on_abort_spares_signal;
          test_case "with_timeout fires" `Quick test_with_timeout_fires;
          test_case "with_timeout releases its timer" `Quick test_with_timeout_releases_timer;
          test_case "choose takes the first reason" `Quick test_choose_first_reason;
          test_case "choose with an aborted input" `Quick test_choose_already_aborted;
          test_case "choose detaches" `Quick test_choose_detaches;
          test_case "choose releases its callbacks" `Quick test_choose_releases_callbacks;
          test_case "wait resolves on failure" `Quick test_wait_resolves_on_failure;
          test_case "cancelling wait spares the signal" `Quick test_cancelling_wait_spares_signal;
          test_case "fail_if_aborted" `Quick test_fail_if_aborted;
          test_case "printer" `Quick test_printer;
        ] );
    ]
