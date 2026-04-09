type error_kind =
  | Api_error of {
      status : int;
      body : string;
    }
  | Network_error of { message : string }
  | Deserialization_error of {
      message : string;
      raw : string;
    }

type t = {
  provider : string;
  kind : error_kind;
  is_retryable : bool;
}

exception Provider_error of t

let to_string { provider; kind; is_retryable = _ } =
  match kind with
  | Api_error { status; body } -> Printf.sprintf "[%s] API error (HTTP %d): %s" provider status body
  | Network_error { message } -> Printf.sprintf "[%s] Network error: %s" provider message
  | Deserialization_error { message; raw } ->
    Printf.sprintf "[%s] Deserialization error: %s (raw: %s)" provider message raw

let is_retryable_status status = status = 408 || status = 409 || status = 429 || status >= 500

let make_api_error ~provider ~status ~body ?is_retryable () =
  let is_retryable = Option.value is_retryable ~default:(is_retryable_status status) in
  { provider; kind = Api_error { status; body }; is_retryable }

let () =
  Printexc.register_printer (function
    | Provider_error e -> Some (to_string e)
    | _ -> None)
