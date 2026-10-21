type 'a t =
  | Completed of 'a list
  | Aborted of 'a list

let is_aborted = Option.fold ~none:false ~some:Ai_provider.Abort_signal.is_aborted

(* Results are kept newest first while the batch runs. *)
let run ~abort_signal f items =
  let run_one batch item =
    match batch with
    | Aborted _ -> Lwt.return batch
    | Completed results ->
      Lwt.catch
        (fun () ->
          let%lwt result = f item in
          Lwt.return (Completed (result :: results)))
        (function
          | Ai_provider.Abort_signal.Aborted _ when is_aborted abort_signal -> Lwt.return (Aborted results)
          | exn -> Lwt.fail exn)
  in
  let%lwt batch = Lwt_list.fold_left_s run_one (Completed []) items in
  match batch with
  | Completed results -> Lwt.return (Completed (List.rev results))
  | Aborted results -> Lwt.return (Aborted (List.rev results))

let results = function
  | Completed results | Aborted results -> results

let fail_if_aborted ~abort_signal = function
  | Completed _ -> Lwt.return_unit
  | Aborted _ ->
    Lwt.fail (Ai_provider.Abort_signal.Aborted { reason = Option.bind abort_signal Ai_provider.Abort_signal.reason })
