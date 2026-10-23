open Alcotest

module Abort_signal = Ai_provider.Abort_signal

let signal_of = Abort_signal.of_promise

(* Runs [f] inside an Lwt callback, as code after any real await runs. *)
let at_depth_1 f = Lwt_main.run (Lwt.bind (Lwt.pause ()) f)

let reason_name signal =
  match Abort_signal.reason signal with
  | None -> "none"
  | Some exn -> Printexc.to_string exn

let test_is_aborted () =
  let pending, (_ : unit Lwt.u) = Lwt.wait () in
  (check bool) "pending" false (Abort_signal.is_aborted (signal_of pending));
  (check bool) "resolved" true (Abort_signal.is_aborted (signal_of Lwt.return_unit));
  (check bool) "failed" true (Abort_signal.is_aborted (signal_of (Lwt.fail Exit)));
  let cancelled, (_ : unit Lwt.u) = Lwt.task () in
  Lwt.cancel cancelled;
  (check bool) "cancelled" true (Abort_signal.is_aborted (signal_of cancelled))

let test_create_with_reason () =
  let signal, abort = Abort_signal.create () in
  abort ~reason:Exit ();
  (check string) "failed with the reason" "Stdlib.Exit" (reason_name signal);
  abort ~reason:Not_found ();
  abort ();
  (check string) "later calls ignored" "Stdlib.Exit" (reason_name signal)

(* Inside a callback, as after any real await, the hooks and waiters still run
   before the abort function returns. *)
let test_create_inside_callback () =
  let signal, abort = Abort_signal.create () in
  let hook_calls = ref 0 in
  let (_ : unit Lwt.t) = Abort_signal.with_on_abort signal (fun () -> incr hook_calls) (fun () -> fst (Lwt.wait ())) in
  let waiting = Abort_signal.wait signal in
  let seen = ref (false, 0, false) in
  at_depth_1 (fun () ->
    abort ();
    seen := Abort_signal.is_aborted signal, !hook_calls, Lwt.is_sleeping waiting;
    Lwt.return_unit);
  let aborted, hook_calls_then, wait_pending = !seen in
  (check bool) "aborted inside the callback" true aborted;
  (check int) "hook ran before abort returned" 1 hook_calls_then;
  (check bool) "wait resolved before abort returned" false wait_pending;
  (check int) "hook ran once" 1 !hook_calls

let test_reason () =
  let pending, (_ : unit Lwt.u) = Lwt.wait () in
  let cancelled, (_ : unit Lwt.u) = Lwt.task () in
  Lwt.cancel cancelled;
  (check (list string))
    "reasons"
    [ "none"; "none"; "Stdlib.Exit"; "none" ]
    (List.map (fun promise -> reason_name (signal_of promise)) [ pending; Lwt.return_unit; Lwt.fail Exit; cancelled ])

let test_with_on_abort_already_settled () =
  let calls = ref 0 in
  let result = Abort_signal.with_on_abort (signal_of Lwt.return_unit) (fun () -> incr calls) (fun () -> Lwt.return 1) in
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

(* The signal is a cancelable task, so a cancel that leaked through the detach
   would settle it. *)
let test_with_on_abort_spares_signal () =
  let promise, (_ : unit Lwt.u) = Lwt.task () in
  let (_ : unit Lwt.t) = Abort_signal.with_on_abort (signal_of promise) ignore (fun () -> Lwt.return_unit) in
  (check bool) "signal still pending" true (Lwt.is_sleeping promise)

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

(* [Lwt_unix.sleep nan] would make the main loop fail with EINVAL. *)
let test_with_timeout_nan () =
  (check bool) "rejected" true
    (match Abort_signal.with_timeout Float.nan (fun (_ : Abort_signal.t) -> Lwt.return_unit) with
    | (_ : unit Lwt.t) -> false
    | exception Invalid_argument _ -> true)

let test_choose_first_reason () =
  let first, (_ : unit Lwt.u) = Lwt.task () in
  let second, abort_second = Lwt.task () in
  let result =
    Abort_signal.choose
      [ signal_of first; signal_of second ]
      (fun signal ->
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
      [ signal_of pending; signal_of (Lwt.fail Not_found); signal_of (Lwt.fail Exit) ]
      (fun signal ->
        reason := reason_name signal;
        Lwt.return_unit)
  in
  (check string) "aborted before f runs, with the first settled input's reason" "Not_found" !reason;
  (check bool) "pending input untouched" true (Lwt.is_sleeping pending)

(* Once [f] settles, settling an input no longer reaches the chosen signal, and
   the inputs were neither settled nor cancelled. *)
let test_choose_detaches () =
  let first, abort_first = Lwt.task () in
  let second, (_ : unit Lwt.u) = Lwt.task () in
  let chosen = ref (signal_of Lwt.return_unit) in
  let (_ : unit Lwt.t) =
    Abort_signal.choose
      [ signal_of first; signal_of second ]
      (fun signal ->
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
    Abort_signal.choose
      [ signal_of input ]
      (fun signal ->
        Weak.set weak 0 (Some signal);
        (match leak with
        | true -> Lwt.on_termination input (fun () -> ignore (Sys.opaque_identity signal : Abort_signal.t))
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
  let promise, (_ : unit Lwt.u) = Lwt.task () in
  Lwt.cancel (Abort_signal.wait (signal_of promise));
  (check bool) "signal still pending" true (Lwt.is_sleeping promise)

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
    (List.map
       (fun promise -> outcome (Option.map signal_of promise))
       [ None; Some pending; Some Lwt.return_unit; Some (Lwt.fail Exit) ])

let outcome_name promise =
  match Lwt.state promise with
  | Lwt.Return value -> "ok: " ^ value
  | Lwt.Fail (Abort_signal.Aborted { reason = None }) -> "aborted"
  | Lwt.Fail (Abort_signal.Aborted { reason = Some reason }) -> "aborted: " ^ Printexc.to_string reason
  | Lwt.Fail exn -> Printexc.to_string exn
  | Lwt.Sleep -> "pending"

let test_guard_already_settled () =
  let signal, abort = Abort_signal.create () in
  abort ~reason:Exit ();
  let ran = ref false in
  let guarded =
    Abort_signal.guard (Some signal) (fun () ->
      ran := true;
      Lwt.return "value")
  in
  (check string) "fails with the reason" "aborted: Stdlib.Exit" (outcome_name guarded);
  (check bool) "thunk not run" false !ran

let test_guard_settles_during_thunk () =
  let signal, abort = Abort_signal.create () in
  let work, finish_work = Lwt.wait () in
  let guarded = Abort_signal.guard (Some signal) (fun () -> work) in
  abort ~reason:Exit ();
  (check string) "waits for the thunk" "pending" (outcome_name guarded);
  Lwt.wakeup_later finish_work "value";
  (check string) "value dropped" "aborted: Stdlib.Exit" (outcome_name guarded);
  let signal, abort = Abort_signal.create () in
  let work, fail_work = Lwt.wait () in
  let guarded = Abort_signal.guard (Some signal) (fun () -> work) in
  abort ();
  Lwt.wakeup_later_exn fail_work Not_found;
  (check string) "failure passes through" "Not_found" (outcome_name guarded)

let test_guard_never_settles () =
  let pending = signal_of (fst (Lwt.wait ())) in
  let work, finish_work = Lwt.wait () in
  let guarded = Abort_signal.guard (Some pending) (fun () -> work) in
  Lwt.wakeup_later finish_work "value";
  (check (list string))
    "outcomes"
    [ "ok: value"; "Not_found"; "ok: value" ]
    [
      outcome_name guarded;
      outcome_name (Abort_signal.guard (Some pending) (fun () -> Lwt.fail Not_found));
      outcome_name (Abort_signal.guard None (fun () -> Lwt.return "value"));
    ]

let test_guard_sync_raise () =
  let pending = signal_of (fst (Lwt.wait ())) in
  let raising () = raise Not_found in
  (check (list string))
    "failed promises" [ "Not_found"; "Not_found" ]
    [ outcome_name (Abort_signal.guard (Some pending) raising); outcome_name (Abort_signal.guard None raising) ]

let test_race_no_signal () =
  (check string) "runs the work" "ok: value" (outcome_name (Abort_signal.race None (fun () -> Lwt.return "value")))

let test_race_already_settled () =
  let signal, abort = Abort_signal.create () in
  abort ~reason:Exit ();
  let ran = ref false in
  let raced =
    Abort_signal.race (Some signal) (fun () ->
      ran := true;
      Lwt.return "value")
  in
  (check string) "fails with the reason" "aborted: Stdlib.Exit" (outcome_name raced);
  (check bool) "work not run" false !ran

(* The work ignores the signal and never returns on its own. *)
let test_race_signal_first () =
  let signal, abort = Abort_signal.create () in
  let work, (_ : string Lwt.u) = Lwt.task () in
  let raced = Abort_signal.race (Some signal) (fun () -> work) in
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
let test_race_work_first () =
  let promise, (_ : unit Lwt.u) = Lwt.task () in
  let work, finish_work = Lwt.wait () in
  let raced = Abort_signal.race (Some (signal_of promise)) (fun () -> work) in
  Lwt.wakeup_later finish_work "value";
  (check string) "work's value" "ok: value" (outcome_name raced);
  (check bool) "signal still pending" true (Lwt.is_sleeping promise)

let test_race_work_fails () =
  let promise, (_ : unit Lwt.u) = Lwt.task () in
  let signal = signal_of promise in
  let raising () = raise Not_found in
  (check (list string))
    "failures pass through as promises"
    [ "Not_found"; "Not_found"; "Not_found" ]
    [
      outcome_name (Abort_signal.race (Some signal) (fun () -> Lwt.fail Not_found));
      outcome_name (Abort_signal.race (Some signal) raising);
      outcome_name (Abort_signal.race None raising);
    ];
  (check bool) "signal still pending" true (Lwt.is_sleeping promise)

(* The work aborts the signal and returns a settled promise. [Lwt.pick] would
   choose between the two at random; [race] returns the work's promise. *)
let test_race_work_settled_with_signal () =
  let outcomes =
    List.init 200 (fun (_ : int) ->
      let signal, abort = Abort_signal.create () in
      outcome_name
        (Abort_signal.race (Some signal) (fun () ->
           abort ();
           Lwt.fail Not_found)))
  in
  (check (list string)) "always the work's failure" [ "Not_found" ] (List.sort_uniq String.compare outcomes)

(* Cancelling the race cancels the work and leaves the signal alone. *)
let test_race_cancelled () =
  let promise, (_ : unit Lwt.u) = Lwt.task () in
  let work, (_ : string Lwt.u) = Lwt.task () in
  let raced = Abort_signal.race (Some (signal_of promise)) (fun () -> work) in
  Lwt.cancel raced;
  let cancelled promise =
    match Lwt.state promise with
    | Lwt.Fail Lwt.Canceled -> true
    | Lwt.Fail _ | Lwt.Return _ | Lwt.Sleep -> false
  in
  (check (list bool)) "race and work cancelled" [ true; true ] [ cancelled raced; cancelled work ];
  (check bool) "signal still pending" true (Lwt.is_sleeping promise)

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
          test_case "create with a reason" `Quick test_create_with_reason;
          test_case "create inside a callback" `Quick test_create_inside_callback;
          test_case "reason" `Quick test_reason;
          test_case "with_on_abort when already settled" `Quick test_with_on_abort_already_settled;
          test_case "with_on_abort during the work" `Quick test_with_on_abort_during_work;
          test_case "with_on_abort detaches on success" `Quick test_with_on_abort_detaches_on_success;
          test_case "with_on_abort spares the signal" `Quick test_with_on_abort_spares_signal;
          test_case "with_timeout fires" `Quick test_with_timeout_fires;
          test_case "with_timeout releases its timer" `Quick test_with_timeout_releases_timer;
          test_case "with_timeout with nan" `Quick test_with_timeout_nan;
          test_case "choose takes the first reason" `Quick test_choose_first_reason;
          test_case "choose with an aborted input" `Quick test_choose_already_aborted;
          test_case "choose detaches" `Quick test_choose_detaches;
          test_case "choose releases its callbacks" `Quick test_choose_releases_callbacks;
          test_case "wait resolves on failure" `Quick test_wait_resolves_on_failure;
          test_case "cancelling wait spares the signal" `Quick test_cancelling_wait_spares_signal;
          test_case "fail_if_aborted" `Quick test_fail_if_aborted;
          test_case "guard when already settled" `Quick test_guard_already_settled;
          test_case "guard settles during the thunk" `Quick test_guard_settles_during_thunk;
          test_case "guard never settles" `Quick test_guard_never_settles;
          test_case "guard with a raising thunk" `Quick test_guard_sync_raise;
          test_case "printer" `Quick test_printer;
        ] );
      ( "race",
        [
          test_case "no signal" `Quick test_race_no_signal;
          test_case "already settled" `Quick test_race_already_settled;
          test_case "signal first" `Quick test_race_signal_first;
          test_case "work first" `Quick test_race_work_first;
          test_case "work fails" `Quick test_race_work_fails;
          test_case "work settled with the signal" `Quick test_race_work_settled_with_signal;
          test_case "cancelled" `Quick test_race_cancelled;
        ] );
    ]
