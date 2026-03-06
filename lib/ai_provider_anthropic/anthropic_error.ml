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

let is_retryable = function
  | Rate_limit_error | Overloaded_error -> true
  | Invalid_request_error | Authentication_error | Permission_error | Not_found_error | Api_error | Unknown_error _ ->
    false

let of_response ~status ~body =
  let message =
    try
      let json = Yojson.Safe.from_string body in
      let error_obj = Yojson.Safe.Util.member "error" json in
      Yojson.Safe.Util.(member "message" error_obj |> to_string)
    with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> body
  in
  { Ai_provider.Provider_error.provider = "anthropic"; kind = Api_error { status; body = message } }
