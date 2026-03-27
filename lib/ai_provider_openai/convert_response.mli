(** Parse OpenAI Chat Completions response into SDK types. *)

(** Map an OpenAI finish reason string to the SDK finish reason. *)
val map_finish_reason : string option -> Ai_provider.Finish_reason.t

(** Parse a full Chat Completions JSON response into a [Generate_result.t]. *)
val parse_response : Yojson.Basic.t -> Ai_provider.Generate_result.t
