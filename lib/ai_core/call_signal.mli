(** The abort signal of a [generate_text] or [stream_text] call. Internal to
    [ai_core]: [Ai_core] does not export this module. *)

(** True when the call has a signal and it has fired. *)
val is_aborted : Ai_provider.Abort_signal.t option -> bool
