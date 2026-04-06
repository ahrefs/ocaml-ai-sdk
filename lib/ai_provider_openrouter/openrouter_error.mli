(** OpenRouter API error handling. *)

(** Parse an HTTP error response into a provider error.
    Extracts structured error messages from OpenRouter's JSON error format,
    including provider name and raw upstream error details when available. *)
val of_response : status:int -> body:string -> Ai_provider.Provider_error.t
