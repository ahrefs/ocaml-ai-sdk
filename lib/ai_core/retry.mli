(** Retry with exponential backoff for provider calls.

    Wraps a thunk and retries on retryable [Provider_error] exceptions
    and transient network errors ([Unix.Unix_error] with [ECONNRESET],
    [ETIMEDOUT], etc.). Other errors are re-raised immediately.
    Matches upstream AI SDK retry behavior. *)

type retry_reason =
  | Max_retries_exceeded
  | Error_not_retryable

type retry_error = {
  message : string;
  reason : retry_reason;
  errors : exn list;
}

exception Retry_error of retry_error

val reason_to_string : retry_reason -> string

(** Retry a thunk with exponential backoff.

    @param max_retries Number of additional attempts after the initial call
      (default 2, matching upstream). Total attempts = 1 + max_retries.
      Set to 0 to disable retries (only the initial call is made).
    @param initial_delay_ms Initial delay in milliseconds (default 2000).
    @param backoff_factor Multiplier applied to delay after each retry (default 2).

    A server [retry_after_s] hint on the error, when present and reasonable,
    REPLACES the exponential backoff for that attempt (it may shorten as well as
    lengthen the delay — it is not a lower bound). Following upstream, a hint of
    [ms] milliseconds is reasonable iff [ms >= 0] and either [ms < 60000] or
    [ms] is below the un-jittered exponential delay for this attempt. Rejected
    hints fall back to the jittered exponential backoff. Jitter never applies to
    an accepted hint.

    @param max_retry_delay_ms Optional maximum retry sleep. An ordinary (backoff)
      delay above this limit is clamped down to it; an accepted server hint above
      this limit instead stops retrying immediately, without sleeping or issuing
      another request.
    @param sleep Function called to sleep between retries (default [Lwt_unix.sleep]).
    @param random Random source in [[0, 1)] used for bounded jitter. *)
val with_retries :
  ?max_retries:int ->
  ?initial_delay_ms:int ->
  ?backoff_factor:int ->
  ?max_retry_delay_ms:int ->
  ?sleep:(float -> unit Lwt.t) ->
  ?random:(unit -> float) ->
  (unit -> 'a Lwt.t) ->
  'a Lwt.t
