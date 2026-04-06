(** OpenRouter usage conversion with extended metrics. *)

type prompt_tokens_details = {
  cached_tokens : int option;
}

type completion_tokens_details = {
  reasoning_tokens : int option;
}

type cost_details = {
  upstream_inference_cost : float option;
}

type openrouter_usage = {
  prompt_tokens : int option;
  completion_tokens : int option;
  total_tokens : int option;
  prompt_tokens_details : prompt_tokens_details option;
  completion_tokens_details : completion_tokens_details option;
  cost : float option;
  cost_details : cost_details option;
}

val openrouter_usage_of_json : Melange_json.t -> openrouter_usage

(** Extended usage metadata for OpenRouter responses. *)
type openrouter_usage_metadata = {
  cache_read_tokens : int;
  reasoning_tokens : int;
  cost : float option;
  upstream_inference_cost : float option;
}

type _ Ai_provider.Provider_options.key +=
  | Openrouter_usage : openrouter_usage_metadata Ai_provider.Provider_options.key

(** Convert to standard SDK usage. *)
val to_usage : openrouter_usage -> Ai_provider.Usage.t

(** Extract extended metadata from usage (defaults to zeros/None if fields are absent). *)
val to_metadata : openrouter_usage -> openrouter_usage_metadata
