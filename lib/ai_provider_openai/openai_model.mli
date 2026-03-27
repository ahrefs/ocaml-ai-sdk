(** OpenAI language model implementation. *)

(** Create an OpenAI language model implementing [Ai_provider.Language_model.S]. *)
val create : config:Config.t -> model:string -> Ai_provider.Language_model.t
