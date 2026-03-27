(** OpenAI usage conversion. *)

type openai_usage = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int option;
}
[@@deriving json]

val to_usage : openai_usage -> Ai_provider.Usage.t
