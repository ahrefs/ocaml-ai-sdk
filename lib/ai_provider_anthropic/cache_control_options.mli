(** Per-content-part cache control via Provider_options.

    Separate from [Anthropic_options] because cache control is per-part
    while [Anthropic_options] is per-request. *)

type _ Ai_provider.Provider_options.key +=
  | Cache : Cache_control.t Ai_provider.Provider_options.key  (** GADT key for per-part cache control. *)

(** Add cache control to provider options. No-op if [cache_control] is [None]. *)
val with_cache_control :
  ?cache_control:Cache_control.t -> Ai_provider.Provider_options.t -> Ai_provider.Provider_options.t

(** Extract cache control from provider options. *)
val get_cache_control : Ai_provider.Provider_options.t -> Cache_control.t option
