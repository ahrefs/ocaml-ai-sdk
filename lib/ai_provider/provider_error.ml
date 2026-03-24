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
}

exception Provider_error of t

let to_string { provider; kind } =
  match kind with
  | Api_error { status; body } -> Printf.sprintf "[%s] API error (HTTP %d): %s" provider status body
  | Network_error { message } -> Printf.sprintf "[%s] Network error: %s" provider message
  | Deserialization_error { message; raw } ->
    Printf.sprintf "[%s] Deserialization error: %s (raw: %s)" provider message raw

let () =
  Printexc.register_printer (function
    | Provider_error e -> Some (to_string e)
    | _ -> None)
