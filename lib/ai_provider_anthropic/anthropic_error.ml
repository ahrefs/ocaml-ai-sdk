open Melange_json.Primitives

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

type error_envelope = { error : error_detail } [@@deriving of_json]

let is_retryable = function
  | Rate_limit_error | Overloaded_error -> true
  | Invalid_request_error | Authentication_error | Permission_error | Not_found_error | Api_error | Unknown_error _ ->
    false

let of_response ~status ~body =
  let error_type, message =
    try
      let json = Yojson.Basic.from_string body in
      let { error = { typ; message } } = error_envelope_of_json json in
      Some (error_type_of_string typ), message
    with
    | Yojson.Json_error _ -> None, body
    | Melange_json.Of_json_error _ -> None, body
  in
  let is_retryable =
    match error_type with
    | Some t -> is_retryable t
    | None -> false
  in
  Ai_provider.Provider_error.make_api_error ~provider:"anthropic" ~status ~body:message ~is_retryable
