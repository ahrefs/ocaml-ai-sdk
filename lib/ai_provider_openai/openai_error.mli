(** OpenAI API error parsing. *)

type openai_error_type =
  | Invalid_request_error
  | Authentication_error
  | Rate_limit_error
  | Not_found_error
  | Server_error
  | Unknown_error of string

val is_retryable : openai_error_type -> bool

(** Parse an HTTP error response into a [Provider_error.t]. *)
val of_response : status:int -> body:string -> Ai_provider.Provider_error.t
