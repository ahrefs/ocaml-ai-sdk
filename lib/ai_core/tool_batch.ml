type 'a t =
  | Completed of 'a list
  | Aborted of 'a list

(* The race stops an item that ignores the signal, and the guard drops a
   result that an item returns after firing the signal itself. Results are
   kept newest first while the batch runs. *)
let run ~abort_signal f items =
  let run_one batch item =
    match batch with
    | Aborted _ -> Lwt.return batch
    | Completed results ->
      Lwt.catch
        (fun () ->
          let%lwt result =
            Ai_provider.Abort_signal.guard abort_signal (fun () ->
              Ai_provider.Abort_signal.race abort_signal (fun () -> f item))
          in
          Lwt.return (Completed (result :: results)))
        (function
          | (_ : exn) when Call_signal.is_aborted abort_signal -> Lwt.return (Aborted results)
          | exn -> Lwt.fail exn)
  in
  let%lwt batch = Lwt_list.fold_left_s run_one (Completed []) items in
  match batch with
  | Completed results -> Lwt.return (Completed (List.rev results))
  | Aborted results -> Lwt.return (Aborted (List.rev results))

let results = function
  | Completed results | Aborted results -> results
