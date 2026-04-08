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

let () =
  Printexc.register_printer (function
    | Retry_error { message; _ } -> Some (Printf.sprintf "Retry_error: %s" message)
    | _ -> None)

let reason_to_string = function
  | Max_retries_exceeded -> "max_retries_exceeded"
  | Error_not_retryable -> "error_not_retryable"

let is_retryable_provider_error = function
  | Ai_provider.Provider_error.Provider_error { is_retryable; _ } -> is_retryable
  | _ -> false

let with_retries ?(max_retries = 2) ?(initial_delay_ms = 2000) ?(backoff_factor = 2) f =
  let rec loop ~delay_ms ~errors_rev ~i =
    Lwt.catch f (fun exn ->
      match max_retries with
      | 0 -> Lwt.fail exn
      | _ ->
        let errors_rev = exn :: errors_rev in
        (match i > max_retries with
        | true ->
          let errors = List.rev errors_rev in
          Lwt.fail
            (Retry_error
               {
                 message = Printf.sprintf "Failed after %d attempts. Last error: %s" i (Printexc.to_string exn);
                 reason = Max_retries_exceeded;
                 errors;
                 last_error = exn;
               })
        | false ->
        match is_retryable_provider_error exn with
        | true ->
          let%lwt () = Lwt_unix.sleep (Float.of_int delay_ms /. 1000.0) in
          loop ~delay_ms:(backoff_factor * delay_ms) ~errors_rev ~i:(i + 1)
        | false ->
        match i with
        | 1 -> Lwt.fail exn
        | _ ->
          let errors = List.rev errors_rev in
          Lwt.fail
            (Retry_error
               {
                 message =
                   Printf.sprintf "Failed after %d attempts with non-retryable error: '%s'" i (Printexc.to_string exn);
                 reason = Error_not_retryable;
                 errors;
                 last_error = exn;
               })))
  in
  loop ~delay_ms:initial_delay_ms ~errors_rev:[] ~i:1
