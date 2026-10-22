(** Caller-side cancellation of provider requests, retries and streams.

    The caller aborts a signal, and the SDK stops the work it was given to.
    {!create} returns a signal and the function that aborts it,
    {!with_timeout} aborts one after a delay, and {!of_promise} turns a
    promise you settle into one. Library code only observes a signal and
    never cancels it.

    {[
      Abort_signal.with_timeout 30. (fun abort_signal ->
        Ai_core.Generate_text.generate_text ~model ~prompt ~abort_signal ())
    ]}

    The
    {{:https://github.com/ahrefs/ocaml-ai-sdk/blob/main/docs/guides/cancellation.md}
    cancellation guide} covers what each SDK function does on an abort, how
    a signal differs from [Lwt.cancel], and how to account for the usage of
    an aborted call.

    A signal may outlive many requests, such as one for server shutdown. Each
    call removes what it registered on the signal when it ends, except that a
    provider request whose transfer is still running keeps its callback until
    the transfer ends. *)

(** A signal is a [unit Lwt.t] that settles on abort. The type is private so
    that code cannot bind or [Lwt.pick] on a signal by accident: [Lwt.pick]
    cancels the promises that lose, which would abort a cancelable signal.
    Read a signal with {!wait}, {!race} or {!guard}. *)
type t = private unit Lwt.t

(** {1 Making a signal} *)

(** [of_promise promise] is a signal that aborts when [promise] settles:
    resolves, fails, whose exception is then the {!reason}, or is cancelled.
    You abort by settling [promise]. [Lwt.cancel] does nothing to a promise
    from [Lwt.wait], so cancelling such a promise never aborts. Prefer
    {!create}, whose abort function always works. *)
val of_promise : unit Lwt.t -> t

(** [create ()] returns a pending signal and the function that aborts it. The
    abort function fails the signal with [reason] when one is given, and
    resolves it otherwise. Everything waiting on the signal, such as
    {!with_on_abort} hooks, {!race} and {!choose}, reacts before the abort
    function returns, so {!is_aborted} is true right after the call. Calling
    it again does nothing. *)
val create : unit -> t * (?reason:exn -> unit -> unit)

(** [with_timeout after_s f] runs [f signal], where [signal] fails with
    [Timeout { after_s }] after [after_s] seconds. A zero or negative
    [after_s] fires at once. The timer is cancelled once [f]'s promise
    settles.

    @raise Invalid_argument if [after_s] is nan. *)
val with_timeout : float -> (t -> 'a Lwt.t) -> 'a Lwt.t

(** [choose signals f] runs [f signal], where [signal] aborts when the first
    of [signals] does, with its reason. When several have already settled,
    the first in the list gives the reason. [choose []] never aborts. Like
    [Lwt.choose], it never cancels [signals]. Unlike it, it removes its
    callbacks from them once [f]'s promise settles, so long-lived signals
    don't leak. [signal] stops following [signals] then, so any work that
    uses it must end before [f]'s promise does. *)
val choose : t list -> (t -> 'a Lwt.t) -> 'a Lwt.t

(** Raised by an operation that a signal interrupted. [reason] is the
    signal's {!reason}. *)
exception Aborted of { reason : exn option }

(** The reason {!with_timeout} gives its signal. *)
exception Timeout of { after_s : float }

(** True once the signal has settled in any way: resolved, failed or
    cancelled. *)
val is_aborted : t -> bool

(** The exception the signal failed with. [None] when it resolved, was
    cancelled ([Lwt.Canceled]) or is still pending. *)
val reason : t -> exn option

(** {1 Code that receives a signal}

    A tool, a custom fetch or a model gets the caller's signal. Read it with
    these functions, never by coercing it to [unit Lwt.t] and binding on
    it. *)

(** [race signal f] runs [f ()] and fails with [Aborted] as soon as [signal]
    settles, cancelling [f]'s promise, even when [f] ignores the signal and
    never returns. It never cancels [signal]. It fails without running [f]
    when [signal] has already settled. When [f]'s promise has settled by the
    time [f] returns, that promise is the result. A failure of [f], raised or
    returned, passes through unchanged. With no signal it is
    [Lwt.apply f ()].

    {[
      let execute args (opts : Ai_core.Core_tool.execute_options) =
        Abort_signal.race opts.abort_signal (fun () -> fetch_page args)
    ]} *)
val race : t option -> (unit -> 'a Lwt.t) -> 'a Lwt.t

(** [guard signal f] runs [f ()], failing with [Aborted] instead when [signal]
    has already settled. When [f]'s promise resolves after [signal] settled,
    it fails with [Aborted] too and drops the value. Unlike {!race}, it waits
    for [f]'s promise. A failure of [f], raised or returned, passes through
    unchanged. With no signal it is [Lwt.apply f ()]. *)
val guard : t option -> (unit -> 'a Lwt.t) -> 'a Lwt.t

(** Fails with [Aborted] when the signal is present and has settled. *)
val fail_if_aborted : t option -> unit Lwt.t

(** A promise that resolves when the signal settles, whether the signal
    resolves, fails or is cancelled. While the signal is pending, it is a new
    promise: cancelling it, for example as a loser of [Lwt.pick], fails it with
    [Lwt.Canceled], leaves the signal untouched and removes its callback from
    the signal. For a signal that has already settled, it may be already
    resolved. *)
val wait : t -> unit Lwt.t

(** [with_on_abort signal hook f] runs [f ()] with [hook] attached to
    [signal]. [hook] runs once when [signal] settles, or right away if it
    already has, unless [f]'s promise has settled first. Once that promise
    settles, by success, failure or cancel, [hook] is removed from [signal].

    [hook] must not raise. An exception from it goes to
    [Lwt.async_exception_hook], which by default prints it and exits the
    process. *)
val with_on_abort : t -> (unit -> unit) -> (unit -> 'a Lwt.t) -> 'a Lwt.t
