open Melange_json.Primitives

type openai_usage = {
  prompt_tokens : int; [@json.default 0]
  completion_tokens : int; [@json.default 0]
  total_tokens : int option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving json]

let to_usage u =
  {
    Ai_provider.Usage.input_tokens = u.prompt_tokens;
    output_tokens = u.completion_tokens;
    total_tokens = Some (Stdlib.Option.value ~default:(u.prompt_tokens + u.completion_tokens) u.total_tokens);
  }
