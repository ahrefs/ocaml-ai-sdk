open Melange_json.Primitives

type openrouter_usage = {
  prompt_tokens : int; [@json.default 0]
  completion_tokens : int; [@json.default 0]
  total_tokens : int option; [@json.default None]
  cache_read_tokens : int option; [@json.default None]
  cache_write_tokens : int option; [@json.default None]
  reasoning_tokens : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type openrouter_usage_metadata = {
  cache_read_tokens : int;
  cache_write_tokens : int;
  reasoning_tokens : int;
}

type _ Ai_provider.Provider_options.key +=
  | Openrouter_usage : openrouter_usage_metadata Ai_provider.Provider_options.key

let to_usage u =
  {
    Ai_provider.Usage.input_tokens = u.prompt_tokens;
    output_tokens = u.completion_tokens;
    total_tokens = Some (Stdlib.Option.value ~default:(u.prompt_tokens + u.completion_tokens) u.total_tokens);
  }

let to_metadata (u : openrouter_usage) =
  {
    cache_read_tokens = Stdlib.Option.value ~default:0 u.cache_read_tokens;
    cache_write_tokens = Stdlib.Option.value ~default:0 u.cache_write_tokens;
    reasoning_tokens = Stdlib.Option.value ~default:0 u.reasoning_tokens;
  }
