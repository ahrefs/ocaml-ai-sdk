type t = unit Lwt.t

exception Aborted of { reason : exn option }

exception Timeout of { after_s : float }

let () =
  Printexc.register_printer (function
    | Aborted { reason = None } -> Some "Abort_signal.Aborted"
    | Aborted { reason = Some reason } -> Some (Printf.sprintf "Abort_signal.Aborted(%s)" (Printexc.to_string reason))
    | Timeout { after_s } -> Some (Printf.sprintf "Abort_signal.Timeout(%gs)" after_s)
    | _ -> None)

let is_aborted signal = not (Lwt.is_sleeping signal)

(* [wakeup_later] sets the state at once; it only defers the signal's
   callbacks when called from inside another callback. *)
let create () =
  let signal, resolver = Lwt.wait () in
  let abort ?reason () =
    match Lwt.is_sleeping signal, reason with
    | false, (_ : exn option) -> ()
    | true, None -> Lwt.wakeup_later resolver ()
    | true, Some reason -> Lwt.wakeup_later_exn resolver reason
  in
  signal, abort

let reason signal =
  match Lwt.state signal with
  | Lwt.Fail Lwt.Canceled | Lwt.Return () | Lwt.Sleep -> None
  | Lwt.Fail reason -> Some reason

(* Callbacks go on a protected copy of the signal, never on the signal itself:
   cancelling the copy removes its callback from the signal, so detached
   observers do not pile up on a long-lived signal. Returns the detach
   function. *)
let on_abort signal f =
  let watch = Lwt.protected signal in
  let attached = ref true in
  Lwt.on_termination watch (fun () -> if !attached then f ());
  fun () ->
    attached := false;
    Lwt.cancel watch

let with_on_abort signal hook f =
  let detach = on_abort signal hook in
  Lwt.finalize f (fun () ->
    detach ();
    Lwt.return_unit)

let with_timeout after_s f =
  let signal, abort = create () in
  let timer =
    let%lwt () = Lwt_unix.sleep after_s in
    abort ~reason:(Timeout { after_s }) ();
    Lwt.return_unit
  in
  Lwt.finalize
    (fun () -> f signal)
    (fun () ->
      Lwt.cancel timer;
      Lwt.return_unit)

let choose signals f =
  let signal, abort = create () in
  let detaches = List.map (fun input -> on_abort input (fun () -> abort ?reason:(reason input) ())) signals in
  Lwt.finalize
    (fun () -> f signal)
    (fun () ->
      List.iter (fun detach -> detach ()) detaches;
      Lwt.return_unit)

(* Never race the raw signal in Lwt.pick: pick cancels the losers, which would
   cancel the caller's promise. Cancelling the protected copy fails it with
   Canceled while the signal is still pending, and that is passed on. *)
let wait signal =
  Lwt.catch
    (fun () -> Lwt.protected signal)
    (fun exn ->
      match Lwt.is_sleeping signal with
      | true -> Lwt.fail exn
      | false -> Lwt.return_unit)

let fail_if_aborted = function
  | Some signal when is_aborted signal -> Lwt.fail (Aborted { reason = reason signal })
  | Some _ | None -> Lwt.return_unit
