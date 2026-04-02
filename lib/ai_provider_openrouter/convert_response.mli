(** OpenRouter response conversion. *)

(** Map OpenRouter finish reason string to SDK finish reason. *)
val map_finish_reason : string option -> Ai_provider.Finish_reason.t

(** Parse a JSON response into a generate result. *)
val parse_response : Yojson.Basic.t -> Ai_provider.Generate_result.t
