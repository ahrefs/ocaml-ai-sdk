(** Convert Anthropic usage to SDK format. *)

type anthropic_usage = {
  input_tokens : int;
  output_tokens : int;
  cache_read_input_tokens : int option;
  cache_creation_input_tokens : int option;
}

(** Parse Anthropic usage from JSON. *)
val anthropic_usage_of_yojson : Yojson.Safe.t -> (anthropic_usage, string) result

(** Convert to SDK Usage. *)
val to_usage : anthropic_usage -> Ai_provider.Usage.t

(** Extract cache-specific metrics into provider metadata. *)
val to_provider_metadata : anthropic_usage -> Ai_provider.Provider_options.t
