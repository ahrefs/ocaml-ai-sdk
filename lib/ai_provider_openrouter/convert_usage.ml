open Melange_json.Primitives

type prompt_tokens_details = {
  cached_tokens : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type completion_tokens_details = {
  reasoning_tokens : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type cost_details = {
  upstream_inference_cost : float option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type openrouter_usage = {
  prompt_tokens : int option; [@json.default None]
  completion_tokens : int option; [@json.default None]
  total_tokens : int option; [@json.default None]
  prompt_tokens_details : prompt_tokens_details option; [@json.default None]
  completion_tokens_details : completion_tokens_details option; [@json.default None]
  cost : float option; [@json.default None]
  cost_details : cost_details option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type openrouter_usage_metadata = {
  cache_read_tokens : int;
  reasoning_tokens : int;
  cost : float option;
  upstream_inference_cost : float option;
}

type _ Ai_provider.Provider_options.key +=
  | Openrouter_usage : openrouter_usage_metadata Ai_provider.Provider_options.key

let to_usage u =
  let input = Stdlib.Option.value ~default:0 u.prompt_tokens in
  let output = Stdlib.Option.value ~default:0 u.completion_tokens in
  {
    Ai_provider.Usage.input_tokens = input;
    output_tokens = output;
    total_tokens = Some (Stdlib.Option.value ~default:(input + output) u.total_tokens);
  }

let to_metadata (u : openrouter_usage) =
  {
    cache_read_tokens =
      (match u.prompt_tokens_details with
      | Some d -> Stdlib.Option.value ~default:0 d.cached_tokens
      | None -> 0);
    reasoning_tokens =
      (match u.completion_tokens_details with
      | Some d -> Stdlib.Option.value ~default:0 d.reasoning_tokens
      | None -> 0);
    cost = u.cost;
    upstream_inference_cost =
      (match u.cost_details with
      | Some d -> d.upstream_inference_cost
      | None -> None);
  }
