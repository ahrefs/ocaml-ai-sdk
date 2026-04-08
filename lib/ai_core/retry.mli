(** Retry with exponential backoff for provider calls.

    Wraps a thunk and retries on retryable [Provider_error] exceptions.
    Non-retryable errors and non-Provider exceptions are re-raised
    immediately. Matches upstream AI SDK retry behavior. *)

type retry_reason =
  | Max_retries_exceeded
  | Error_not_retryable

type retry_error = {
  message : string;
  reason : retry_reason;
  errors : exn list;
  last_error : exn;
}

exception Retry_error of retry_error

val reason_to_string : retry_reason -> string

(** Retry a thunk with exponential backoff.

    @param max_retries Maximum number of retries (default 2, matching upstream).
      Set to 0 to disable retries.
    @param initial_delay_ms Initial delay in milliseconds (default 2000).
    @param backoff_factor Multiplier applied to delay after each retry (default 2). *)
val with_retries : ?max_retries:int -> ?initial_delay_ms:int -> ?backoff_factor:int -> (unit -> 'a Lwt.t) -> 'a Lwt.t
