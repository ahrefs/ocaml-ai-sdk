type 'a t =
  | Completed of 'a list
  | Aborted of 'a list

(* The race stops an item that ignores the signal, telemetry included, and
   the guard drops a result that a tool returns after firing the signal
   itself. A result is kept as soon as [execute] returns it, so an abort
   while the item goes on to report it, which the race turns into a cancel,
   cannot lose it. Results are kept newest first while the batch runs. *)
let run ~abort_signal f items =
  let run_one batch item =
    match batch with
    | Aborted _ -> Lwt.return batch
    | Completed results ->
      let results = ref results in
      let execute work =
        let%lwt result = Ai_provider.Abort_signal.guard abort_signal work in
        results := result :: !results;
        Lwt.return result
      in
      Lwt.catch
        (fun () ->
          let%lwt () = Ai_provider.Abort_signal.race abort_signal (fun () -> f item ~execute) in
          Lwt.return (Completed !results))
        (function
          | (_ : exn) when Call_signal.is_aborted abort_signal -> Lwt.return (Aborted !results)
          | exn -> Lwt.fail exn)
  in
  let%lwt batch = Lwt_list.fold_left_s run_one (Completed []) items in
  match batch with
  | Completed results -> Lwt.return (Completed (List.rev results))
  | Aborted results -> Lwt.return (Aborted (List.rev results))

let results = function
  | Completed results | Aborted results -> results
