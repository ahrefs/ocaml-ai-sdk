open Melange_json.Primitives

type cache_creation = {
  ephemeral_5m_input_tokens : int; [@json.default 0]
  ephemeral_1h_input_tokens : int; [@json.default 0]
}
[@@deriving json]

type anthropic_usage = {
  input_tokens : int; [@json.default 0]
  output_tokens : int; [@json.default 0]
  cache_read_input_tokens : int option; [@json.default None]
  cache_creation_input_tokens : int option; [@json.default None]
  cache_creation : cache_creation option; [@json.default None]
  service_tier : string option; [@json.default None]
  inference_geo : string option; [@json.default None]
}
[@@deriving json]

let to_usage u =
  {
    Ai_provider.Usage.input_tokens = u.input_tokens;
    output_tokens = u.output_tokens;
    total_tokens = Some (u.input_tokens + u.output_tokens);
  }

type _ Ai_provider.Provider_options.key += Cache_metrics : anthropic_usage Ai_provider.Provider_options.key

let to_provider_metadata u = Ai_provider.Provider_options.set Cache_metrics u Ai_provider.Provider_options.empty
