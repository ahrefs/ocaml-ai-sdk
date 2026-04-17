type timeout_phase =
  [ `Request_headers
  | `Stream_idle
  ]

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
  | Timeout of {
      phase : timeout_phase;
      elapsed_s : float;
      limit_s : float;
    }

type t = {
  provider : string;
  kind : error_kind;
  is_retryable : bool;
}

exception Provider_error of t

let phase_to_string = function
  | `Request_headers -> "response headers"
  | `Stream_idle -> "stream idle"

let to_string { provider; kind; _ } =
  match kind with
  | Api_error { status; body } -> Printf.sprintf "[%s] API error (HTTP %d): %s" provider status body
  | Network_error { message } -> Printf.sprintf "[%s] Network error: %s" provider message
  | Deserialization_error { message; raw } ->
    Printf.sprintf "[%s] Deserialization error: %s (raw: %s)" provider message raw
  | Timeout { phase; elapsed_s; limit_s } ->
    Printf.sprintf "[%s] HTTP timeout waiting for %s after %.1fs (limit: %.1fs)"
      provider (phase_to_string phase) elapsed_s limit_s

let is_retryable_status status = status = 408 || status = 409 || status = 429 || status >= 500

let make_api_error ~provider ~status ~body ?is_retryable () =
  let is_retryable = Option.value is_retryable ~default:(is_retryable_status status) in
  { provider; kind = Api_error { status; body }; is_retryable }

let timeout_is_retryable = function
  | `Request_headers -> false
  | `Stream_idle -> true

let make_timeout ~provider ~phase ~elapsed_s ~limit_s =
  {
    provider;
    kind = Timeout { phase; elapsed_s; limit_s };
    is_retryable = timeout_is_retryable phase;
  }

let () =
  Printexc.register_printer (function
    | Provider_error e -> Some (to_string e)
    | _ -> None)
