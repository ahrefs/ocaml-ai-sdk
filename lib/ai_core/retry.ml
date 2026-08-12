type retry_reason =
  | Max_retries_exceeded
  | Error_not_retryable

type retry_error = {
  message : string;
  reason : retry_reason;
  errors : exn list;
}

exception Retry_error of retry_error

let () =
  Printexc.register_printer (function
    | Retry_error { message; _ } -> Some (Printf.sprintf "Retry_error: %s" message)
    | _ -> None)

let reason_to_string = function
  | Max_retries_exceeded -> "max_retries_exceeded"
  | Error_not_retryable -> "error_not_retryable"

let error_message ~reason ~attempts exn =
  match reason with
  | Max_retries_exceeded -> Printf.sprintf "Failed after %d attempts. Last error: %s" attempts (Printexc.to_string exn)
  | Error_not_retryable ->
    Printf.sprintf "Failed after %d attempts with non-retryable error: '%s'" attempts (Printexc.to_string exn)

let is_transient_network_error = function
  | Unix.Unix_error ((ECONNRESET | ECONNREFUSED | ETIMEDOUT | EPIPE | ENETUNREACH | EHOSTUNREACH), _, _) -> true
  | _ -> false

let is_retryable_error = function
  | Ai_provider.Provider_error.Provider_error { is_retryable; _ } -> is_retryable
  | exn -> is_transient_network_error exn

let retry_after_s = function
  | Ai_provider.Provider_error.Provider_error { retry_after_s = Some delay; _ }
    when Float.is_finite delay && delay >= 0.0 ->
    Some delay
  | Ai_provider.Provider_error.Provider_error _ -> None
  | _ -> None

let with_retries ?(max_retries = 2) ?(initial_delay_ms = 2000) ?(backoff_factor = 2) ?max_retry_delay_ms
  ?(sleep = Lwt_unix.sleep) ?random f =
  if max_retries < 0 then invalid_arg "Retry.with_retries: max_retries must be >= 0";
  if initial_delay_ms < 0 then invalid_arg "Retry.with_retries: initial_delay_ms must be >= 0";
  if backoff_factor < 1 then invalid_arg "Retry.with_retries: backoff_factor must be >= 1";
  (match max_retry_delay_ms with
  | Some delay when delay < 0 -> invalid_arg "Retry.with_retries: max_retry_delay_ms must be >= 0"
  | Some _ | None -> ());
  let random =
    match random with
    | Some random -> random
    | None ->
      let state = Random.State.make_self_init () in
      fun () -> Random.State.float state 1.0
  in
  let make_retry_error ~reason ~errors_rev exn =
    let errors = List.rev errors_rev in
    Retry_error { message = error_message ~reason ~attempts:(List.length errors) exn; reason; errors }
  in
  let rec loop ~delay_ms ~errors_rev ~i =
    Lwt.catch f (fun exn ->
      let errors_rev = exn :: errors_rev in
      match () with
      | () when max_retries = 0 -> Lwt.fail exn
      | () when i > max_retries -> Lwt.fail (make_retry_error ~reason:Max_retries_exceeded ~errors_rev exn)
      | () when is_retryable_error exn ->
        (* Un-jittered exponential delay for this attempt, in ms. The hint's
           reasonableness is judged against this deterministic value (matching
           upstream's [delayInMs]); jitter applies only to the backoff branch. *)
        let unjittered_delay_ms = Float.of_int delay_ms in
        (* A hint (seconds) is accepted iff its ms value is non-negative and
           either below 60s or below the un-jittered backoff. An accepted hint
           REPLACES the backoff; a rejected one falls back to jittered backoff. *)
        let accepted_hint_s =
          match retry_after_s exn with
          | Some hint_s when hint_s *. 1000.0 < 60_000.0 || hint_s *. 1000.0 < unjittered_delay_ms -> Some hint_s
          | Some _ | None -> None
        in
        let jitter = 0.5 +. Float.max 0.0 (Float.min 1.0 (random ())) in
        let backoff_s = unjittered_delay_ms *. jitter /. 1000.0 in
        let advance () =
          let next_delay_ms = if delay_ms > max_int / backoff_factor then max_int else backoff_factor * delay_ms in
          loop ~delay_ms:next_delay_ms ~errors_rev ~i:(i + 1)
        in
        (* Selected delay: accepted hint or jittered backoff. The cap then acts
           differently by source: an accepted hint above the cap STOPS retrying
           without sleeping; a backoff above the cap is CLAMPED and retried. *)
        (match accepted_hint_s, max_retry_delay_ms with
        | Some hint_s, Some max_ms when hint_s *. 1000.0 > Float.of_int max_ms ->
          Lwt.fail (make_retry_error ~reason:Max_retries_exceeded ~errors_rev exn)
        | Some hint_s, _ ->
          let%lwt () = sleep hint_s in
          advance ()
        | None, _ ->
          let delay_s =
            Option.fold ~none:backoff_s
              ~some:(fun max_ms -> Float.min backoff_s (Float.of_int max_ms /. 1000.0))
              max_retry_delay_ms
          in
          let%lwt () = sleep delay_s in
          advance ())
      | () when i = 1 -> Lwt.fail exn
      | () -> Lwt.fail (make_retry_error ~reason:Error_not_retryable ~errors_rev exn))
  in
  loop ~delay_ms:initial_delay_ms ~errors_rev:[] ~i:1
