let is_aborted = Option.fold ~none:false ~some:Ai_provider.Abort_signal.is_aborted
