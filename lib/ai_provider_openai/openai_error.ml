open Melange_json.Primitives

type openai_error_type =
  | Invalid_request_error
  | Authentication_error
  | Rate_limit_error
  | Not_found_error
  | Server_error
  | Unknown_error of string

type error_detail = {
  typ : string; [@json.key "type"] [@json.default "unknown"]
  message : string; [@json.default ""]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type error_envelope = { error : error_detail } [@@json.allow_extra_fields] [@@deriving of_json]

let error_type_of_string = function
  | "invalid_request_error" -> Invalid_request_error
  | "authentication_error" -> Authentication_error
  | "rate_limit_error" -> Rate_limit_error
  | "not_found_error" -> Not_found_error
  | "server_error" -> Server_error
  | s -> Unknown_error s

let is_retryable = function
  | Rate_limit_error | Server_error -> true
  | Invalid_request_error | Authentication_error | Not_found_error | Unknown_error _ -> false

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
  let retryable =
    match error_type with
    | Some t -> is_retryable t
    | None -> false
  in
  {
    Ai_provider.Provider_error.provider = "openai";
    kind = Api_error { status; body = message };
    is_retryable = retryable;
  }
