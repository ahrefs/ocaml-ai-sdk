(** Racing work against an abort signal. Internal to [ai_core]: [Ai_core]
    does not export this module. *)

(** [race signal f] runs [f ()] and fails with
    [Ai_provider.Abort_signal.Aborted] as soon as [signal] settles, cancelling
    [f]'s promise, even when [f] ignores the signal and never returns. It
    races {!Ai_provider.Abort_signal.wait}, so it never cancels [signal].
    Like {!Ai_provider.Abort_signal.guard}, it fails without running [f] when
    [signal] has already settled, and drops a value that arrives once
    [signal] has settled. A failure of [f], raised or returned, passes through
    unchanged. With no signal it is [Lwt.apply f ()]. *)
val race : Ai_provider.Abort_signal.t option -> (unit -> 'a Lwt.t) -> 'a Lwt.t
