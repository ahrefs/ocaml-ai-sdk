let is_aborted = Option.fold ~none:false ~some:Ai_provider.Abort_signal.is_aborted

let aborted signal =
  match signal with
  | Some signal when Ai_provider.Abort_signal.is_aborted signal ->
    Some (Ai_provider.Abort_signal.Aborted { reason = Ai_provider.Abort_signal.reason signal })
  | Some _ | None -> None
