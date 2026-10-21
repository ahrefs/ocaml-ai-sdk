(** Caller-side cancellation of provider requests, retries and streams.

    A signal is a promise owned by the caller, who aborts by settling it:
    resolving it, failing it with a reason, or cancelling it when it is
    cancelable. {!create} returns a signal and the function that aborts it.
    Library code only observes the signal and never cancels it.

    Two traps when building a signal by hand:
    - [Lwt.cancel] does nothing to a promise from [Lwt.wait], so cancelling
      such a signal never aborts. Use {!create} and its abort function.
    - [Lwt.pick] cancels the promises that lose, so a [Lwt.pick [signal; ...]]
      in your own code cancels, and so aborts, a cancelable signal such as one
      from [Lwt.task]. Race {!wait} instead, or combine signals with {!choose}.

    A signal may outlive many requests, such as one for server shutdown. Each
    request removes what it registered on the signal when it finishes. *)

type t = unit Lwt.t

(** Raised by an operation that a signal interrupted. [reason] is the
    signal's {!reason}. *)
exception Aborted of { reason : exn option }

(** The reason {!with_timeout} gives its signal. *)
exception Timeout of { after_s : float }

(** [create ()] returns a pending signal and the function that aborts it. The
    abort function fails the signal with [reason] when one is given, and
    resolves it otherwise. The signal has settled when it returns, so
    {!is_aborted} is true right after the call. Calling it again does
    nothing. *)
val create : unit -> t * (?reason:exn -> unit -> unit)

(** True once the signal has settled in any way: resolved, failed or
    cancelled. *)
val is_aborted : t -> bool

(** The exception the signal failed with. [None] when it resolved, was
    cancelled ([Lwt.Canceled]) or is still pending. *)
val reason : t -> exn option

(** [with_timeout after_s f] runs [f signal], where [signal] fails with
    [Timeout { after_s }] after [after_s] seconds. The timer is cancelled once
    [f]'s promise settles. *)
val with_timeout : float -> (t -> 'a Lwt.t) -> 'a Lwt.t

(** [choose signals f] runs [f signal], where [signal] aborts when the first
    of [signals] does, with its reason. Like [Lwt.choose], it never cancels
    [signals]; unlike it, it removes its callbacks from them once [f]'s
    promise settles, so long-lived signals don't leak. *)
val choose : t list -> (t -> 'a Lwt.t) -> 'a Lwt.t

(** [with_on_abort signal hook f] runs [f ()] with [hook] attached to
    [signal]. [hook] runs once when [signal] settles, or right away if it
    already has, unless [f]'s promise has settled first. Once that promise
    settles, by success, failure or cancel, [hook] is removed from [signal].

    [hook] must not raise. An exception from it goes to
    [Lwt.async_exception_hook], which by default prints it and exits the
    process. *)
val with_on_abort : t -> (unit -> unit) -> (unit -> 'a Lwt.t) -> 'a Lwt.t

(** A promise that resolves when the signal settles, whether the signal
    resolves, fails or is cancelled. While the signal is pending, it is a new
    promise: cancelling it, for example as a loser of [Lwt.pick], fails it with
    [Lwt.Canceled], leaves the signal untouched and removes its callback from
    the signal. For a signal that has already settled, it may be already
    resolved. *)
val wait : t -> unit Lwt.t

(** Fails with [Aborted] when the signal is present and has settled. *)
val fail_if_aborted : t option -> unit Lwt.t

(** [guard signal f] runs [f ()], failing with [Aborted] instead when [signal]
    has already settled. When [f]'s promise resolves after [signal] settled,
    it fails with [Aborted] too and drops the value. A failure of [f], raised
    or returned, passes through unchanged. With no signal it is
    [Lwt.apply f ()]. *)
val guard : t option -> (unit -> 'a Lwt.t) -> 'a Lwt.t
