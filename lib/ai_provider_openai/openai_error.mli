(** OpenAI API error parsing. *)

type openai_error_type =
  | Invalid_request_error
  | Authentication_error
  | Rate_limit_error
  | Not_found_error
  | Server_error
  | Unknown_error of string

val is_retryable : openai_error_type -> bool

(** Parse an HTTP error response into a [Provider_error.t]. Optional
    [retry_after_ms] and [retry_after] response headers populate [retry_after_s];
    [retry_after_ms] takes precedence (see {!Ai_provider.Retry_after.parse}).
    OpenAI emits the more precise [retry-after-ms] header. *)
val of_response :
  ?retry_after_ms:string option ->
  ?retry_after:string option ->
  status:int ->
  body:string ->
  unit ->
  Ai_provider.Provider_error.t
