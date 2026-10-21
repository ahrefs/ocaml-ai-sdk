module Abort_signal = Ai_provider.Abort_signal

let race signal f =
  match signal with
  | None -> Lwt.apply f ()
  | Some watched ->
    Abort_signal.guard signal (fun () ->
      Lwt.pick
        [
          Lwt.apply f ();
          (let%lwt () = Abort_signal.wait watched in
           Lwt.fail (Abort_signal.Aborted { reason = Abort_signal.reason watched }));
        ])
