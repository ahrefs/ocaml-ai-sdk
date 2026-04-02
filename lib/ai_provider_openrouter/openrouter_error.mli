(** OpenRouter API error handling. *)

type openrouter_error_type =
  | Invalid_request_error
  | Authentication_error
  | Rate_limit_error
  | Not_found_error
  | Server_error
  | Unknown_error of string

val error_type_of_string : string -> openrouter_error_type
val is_retryable : openrouter_error_type -> bool

(** Parse an HTTP error response into a provider error. *)
val of_response : status:int -> body:string -> Ai_provider.Provider_error.t
