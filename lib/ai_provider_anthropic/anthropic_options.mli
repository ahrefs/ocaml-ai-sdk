(** Anthropic-specific provider options. *)

type structured_output_mode =
  | Auto
  | Output_format
  | Json_tool

type t = {
  thinking : Thinking.t option;
  cache_control : Cache_control.t option;
  tool_streaming : bool;
  structured_output_mode : structured_output_mode;
}

(** Default options: no thinking, no cache control, tool streaming enabled,
    auto structured output. *)
val default : t

type _ Ai_provider.Provider_options.key +=
  | Anthropic : t Ai_provider.Provider_options.key
      (** GADT key for Anthropic-specific options in [Provider_options.t]. *)

(** Wrap into a [Provider_options.t]. *)
val to_provider_options : t -> Ai_provider.Provider_options.t

(** Extract from a [Provider_options.t]. Returns [None] if absent. *)
val of_provider_options : Ai_provider.Provider_options.t -> t option
