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
  let rec loop ~delay_ms ~errors =
    let try_number = List.length errors + 1 in
    Lwt.catch f (fun exn ->
      match max_retries with
      | 0 -> Lwt.fail exn
      | _ ->
        let new_errors = errors @ [ exn ] in
        let try_count = List.length new_errors in
        (match try_count > max_retries with
        | true ->
          Lwt.fail
            (Retry_error
               {
                 message = Printf.sprintf "Failed after %d attempts. Last error: %s" try_count (Printexc.to_string exn);
                 reason = Max_retries_exceeded;
                 errors = new_errors;
                 last_error = exn;
               })
        | false ->
        match is_retryable_provider_error exn with
        | true ->
          let%lwt () = Lwt_unix.sleep (Float.of_int delay_ms /. 1000.0) in
          loop ~delay_ms:(backoff_factor * delay_ms) ~errors:new_errors
        | false ->
        match try_number with
        | 1 -> Lwt.fail exn
        | _ ->
          Lwt.fail
            (Retry_error
               {
                 message =
                   Printf.sprintf "Failed after %d attempts with non-retryable error: '%s'" try_count
                     (Printexc.to_string exn);
                 reason = Error_not_retryable;
                 errors = new_errors;
                 last_error = exn;
               })))
  in
  loop ~delay_ms:initial_delay_ms ~errors:[]
