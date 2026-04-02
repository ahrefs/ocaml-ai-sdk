(** OpenRouter language model implementation. *)

(** Create an OpenRouter language model implementing [Ai_provider.Language_model.S]. *)
val create : config:Config.t -> model:string -> Ai_provider.Language_model.t
