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
  | Ai_provider.Provider_error.Provider_error { retry_after_s; _ } -> retry_after_s
  | _ -> None

let with_retries ?(max_retries = 2) ?(initial_delay_ms = 2000) ?(backoff_factor = 2) ?max_retry_delay_ms
  ?(sleep = Lwt_unix.sleep) ?(random = fun () -> Random.float 1.0) f =
  if max_retries < 0 then invalid_arg "Retry.with_retries: max_retries must be >= 0";
  if initial_delay_ms < 0 then invalid_arg "Retry.with_retries: initial_delay_ms must be >= 0";
  if backoff_factor < 1 then invalid_arg "Retry.with_retries: backoff_factor must be >= 1";
  (match max_retry_delay_ms with
  | Some delay when delay < 0 -> invalid_arg "Retry.with_retries: max_retry_delay_ms must be >= 0"
  | Some _ | None -> ());
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
        let jitter = 0.5 +. Float.max 0.0 (Float.min 1.0 (random ())) in
        let backoff_s = Float.of_int delay_ms *. jitter /. 1000.0 in
        let delay_s = Option.fold ~none:backoff_s ~some:(Float.max backoff_s) (retry_after_s exn) in
        (match max_retry_delay_ms with
        | Some max_ms when delay_s *. 1000.0 > Float.of_int max_ms ->
          Lwt.fail (make_retry_error ~reason:Max_retries_exceeded ~errors_rev exn)
        | Some _ | None ->
          let%lwt () = sleep delay_s in
          loop ~delay_ms:(backoff_factor * delay_ms) ~errors_rev ~i:(i + 1))
      | () when i = 1 -> Lwt.fail exn
      | () -> Lwt.fail (make_retry_error ~reason:Error_not_retryable ~errors_rev exn))
  in
  loop ~delay_ms:initial_delay_ms ~errors_rev:[] ~i:1
