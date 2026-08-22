(** Anthropic model implementing [Ai_provider.Language_model.S]. *)

(** Create a language model backed by the Anthropic Messages API. *)
val create : config:Config.t -> model:string -> Ai_provider.Language_model.t

(** Message for an effort level a model does not accept. Exposed for tests: no
    catalog model has a partial [effort_levels] list, so the branch naming the
    accepted levels is unreachable through {!create}. *)
val unsupported_effort_message : model:string -> effort:Effort.t -> accepted:Effort.t list -> string
