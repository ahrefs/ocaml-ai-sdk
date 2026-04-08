(** Convert Anthropic usage to SDK format. *)

type cache_creation = {
  ephemeral_5m_input_tokens : int;
  ephemeral_1h_input_tokens : int;
}

type anthropic_usage = {
  input_tokens : int;
  output_tokens : int;
  cache_read_input_tokens : int option;
  cache_creation_input_tokens : int option;
  cache_creation : cache_creation option;
  service_tier : string option;
  inference_geo : string option;
}

(** Parse Anthropic usage from JSON. *)
val anthropic_usage_of_json : Yojson.Basic.t -> anthropic_usage

(** Convert Anthropic usage to JSON. *)
val anthropic_usage_to_json : anthropic_usage -> Yojson.Basic.t

(** Convert to SDK Usage. *)
val to_usage : anthropic_usage -> Ai_provider.Usage.t

(** Extract cache-specific metrics into provider metadata. *)
val to_provider_metadata : anthropic_usage -> Ai_provider.Provider_options.t
