(** OpenRouter usage conversion with extended metrics. *)

type openrouter_usage = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int option;
  cache_read_tokens : int option;
  cache_write_tokens : int option;
  reasoning_tokens : int option;
}

val openrouter_usage_of_json : Melange_json.t -> openrouter_usage

(** Extended usage metadata for OpenRouter responses. *)
type openrouter_usage_metadata = {
  cache_read_tokens : int;
  cache_write_tokens : int;
  reasoning_tokens : int;
}

type _ Ai_provider.Provider_options.key +=
  | Openrouter_usage : openrouter_usage_metadata Ai_provider.Provider_options.key

(** Convert to standard SDK usage. *)
val to_usage : openrouter_usage -> Ai_provider.Usage.t

(** Extract extended metadata from usage (all zeros if fields are absent). *)
val to_metadata : openrouter_usage -> openrouter_usage_metadata
