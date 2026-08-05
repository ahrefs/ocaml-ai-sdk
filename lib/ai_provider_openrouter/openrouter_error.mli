(** OpenRouter API error handling. *)

(** Parse an HTTP error response into a provider error.
    Extracts the most specific readable message from OpenRouter's JSON error
    envelope (upstream provider name, raw upstream error, and error_type when
    available). The HTTP [status] is authoritative for retryability. *)
val of_response : status:int -> body:string -> Ai_provider.Provider_error.t

(** As {!of_response}, parsing and preserving a raw Retry-After header. *)
val of_response_with_retry_after :
  status:int -> body:string -> retry_after:string option -> Ai_provider.Provider_error.t

(** Build a Provider_error from an OpenRouter [error] object.
    Pass [status] on the HTTP error path so retryability keys off the real
    gateway status; omit it for 200-embedded, choice-level, and streaming
    errors, where the status is derived from [error.code] (default 200). *)
val of_error_json : ?status:int -> ?retry_after_s:float -> Yojson.Basic.t -> Ai_provider.Provider_error.t
