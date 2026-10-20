(** Caller-side cancellation of provider requests, retries and streams.

    A signal is a promise owned by the caller, who aborts by resolving it or
    failing it. Cancelling it also aborts when the promise is cancelable, as
    one from [Lwt.task] is; [Lwt.cancel] does nothing to a promise from
    [Lwt.wait]. Library code only observes the promise and never cancels it.

    A signal may outlive many requests, such as one for server shutdown. Each
    request releases what it registered on the signal when it finishes: a
    detached [on_abort] callback and a cancelled [wait] promise are dropped
    from the signal. *)

type t = unit Lwt.t

(** Raised by an operation that a signal interrupted. *)
exception Aborted

(** True once the signal has settled in any way: resolved, failed or
    cancelled. *)
val is_aborted : t -> bool

(** [on_abort signal f] runs [f] once when [signal] settles, or before
    returning if it already has. It returns a detach function. After a detach,
    [f] never runs and the signal no longer holds [f]. Detaching more than
    once, or after [f] ran, does nothing. Call it when the operation that
    registered [f] ends, so a long-lived signal does not keep [f] alive.

    [f] must not raise. An exception from it goes to [Lwt.async_exception_hook],
    which by default prints it and exits the process. *)
val on_abort : t -> (unit -> unit) -> unit -> unit

(** A promise that resolves when the signal settles, whether the signal
    resolves, fails or is cancelled. While the signal is pending, it is a new
    promise: cancelling it, for example as a loser of [Lwt.pick], fails it with
    [Lwt.Canceled], leaves the signal untouched and removes its callback from
    the signal. For a signal that has already settled, it may be already
    resolved. *)
val wait : t -> unit Lwt.t

(** Fails with [Aborted] when the signal is present and has settled. *)
val fail_if_aborted : t option -> unit Lwt.t
