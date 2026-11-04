open Jsonkit.Primitives

type openai_usage = {
  prompt_tokens : int; [@json.default 0]
  completion_tokens : int; [@json.default 0]
  total_tokens : int option; [@json.default None]
}
[@@deriving json]

let to_usage u =
  {
    Ai_provider.Usage.input_tokens = u.prompt_tokens;
    output_tokens = u.completion_tokens;
    total_tokens = Some (Stdlib.Option.value ~default:(u.prompt_tokens + u.completion_tokens) u.total_tokens);
  }
