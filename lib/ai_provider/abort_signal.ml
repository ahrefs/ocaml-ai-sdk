type t = unit Lwt.t

exception Aborted

let () =
  Printexc.register_printer (function
    | Aborted -> Some "Abort_signal.Aborted"
    | _ -> None)

let is_aborted signal = not (Lwt.is_sleeping signal)

(* Callbacks go on a protected copy of the signal, never on the signal itself:
   cancelling the copy removes its callback from the signal, so detached
   observers do not pile up on a long-lived signal. *)
let on_abort signal f =
  let watch = Lwt.protected signal in
  let attached = ref true in
  Lwt.on_termination watch (fun () -> if !attached then f ());
  fun () ->
    attached := false;
    Lwt.cancel watch

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
  | Some signal when is_aborted signal -> Lwt.fail Aborted
  | Some _ | None -> Lwt.return_unit
