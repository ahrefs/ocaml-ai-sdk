(** Anthropic API error types and parsing. *)

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

(** Parse an Anthropic error HTTP response. Optional [retry_after_ms] and
    [retry_after] response headers populate [retry_after_s] on the result;
    [retry_after_ms] takes precedence (see {!Ai_provider.Retry_after.parse}). *)
val of_response :
  ?retry_after_ms:string option ->
  ?retry_after:string option ->
  status:int ->
  body:string ->
  unit ->
  Ai_provider.Provider_error.t

(** [Rate_limit_error] and [Overloaded_error] are retryable. *)
val is_retryable : anthropic_error_type -> bool

val error_type_of_string : string -> anthropic_error_type
