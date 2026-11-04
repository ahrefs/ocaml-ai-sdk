open Jsonkit.Primitives

type anthropic_error_type =
  | Invalid_request_error
  | Authentication_error
  | Permission_error
  | Not_found_error
  | Rate_limit_error
  | Api_error
  | Overloaded_error
  | Unknown_error of string

type anthropic_error = {
  error_type : anthropic_error_type;
  message : string;
}

let error_type_of_string = function
  | "invalid_request_error" -> Invalid_request_error
  | "authentication_error" -> Authentication_error
  | "permission_error" -> Permission_error
  | "not_found_error" -> Not_found_error
  | "rate_limit_error" -> Rate_limit_error
  | "api_error" -> Api_error
  | "overloaded_error" -> Overloaded_error
  | s -> Unknown_error s

type error_detail = {
  typ : string; [@json.key "type"]
  message : string;
}
[@@deriving of_json]

type error_envelope = {
  error : error_detail;
  request_id : string option; [@json.default None]
}
[@@deriving of_json]

let is_retryable = function
  | Rate_limit_error | Overloaded_error -> true
  | Invalid_request_error | Authentication_error | Permission_error | Not_found_error | Api_error | Unknown_error _ ->
    false

(* Keeps the error type and request id in the message, since [Api_error]
   carries no other field for them and Anthropic support asks for the id. *)
let format_message ~typ ~message ~request_id =
  match request_id with
  | Some id -> Printf.sprintf "%s: %s (request_id: %s)" typ message id
  | None -> Printf.sprintf "%s: %s" typ message

let of_response ?(retry_after_ms = None) ?(retry_after = None) ~status ~body () =
  let type_forces_retry, message =
    try
      let { error = { typ; message }; request_id } = error_envelope_of_json (Yojson.Basic.from_string body) in
      is_retryable (error_type_of_string typ), format_message ~typ ~message ~request_id
    with Yojson.Json_error _ | Jsonkit.Of_json_error _ -> false, body
  in
  (* Otherwise the status rule decides, as in upstream's APICallError. *)
  let is_retryable = if type_forces_retry then Some true else None in
  let retry_after_s = Ai_provider.Retry_after.parse ~retry_after_ms ~retry_after in
  Ai_provider.Provider_error.make_api_error ~provider:"anthropic" ~status ~body:message ?is_retryable ?retry_after_s ()
