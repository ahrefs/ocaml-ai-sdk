(** Known Anthropic models with capabilities metadata. *)

type disabled_thinking_support =
  | Allowed
  | Up_to_high
  | Unsupported

type thinking_capabilities = {
  manual : bool;
  adaptive : bool;
  defaults_to_adaptive : bool;
  disabled : disabled_thinking_support;
  effort_levels : Effort.t list;
  display_default : Thinking.display option;
}

type model_capabilities = {
  max_output_tokens : int;
  thinking : thinking_capabilities option;
  rejects_sampling_parameters : bool;
  supports_structured_output : bool;
  supports_prompt_caching : bool;
  min_cache_tokens : int;
  supports_vision : bool;
  supports_pdf : bool;
}

type known_model =
  | Claude_fable_5
  | Claude_mythos_5
  | Claude_opus_5
  | Claude_opus_4_8
  | Claude_sonnet_5
  | Claude_haiku_4_5
  | Custom of string

(** Convert a known model to its API model ID string. *)
val to_model_id : known_model -> string

(** Parse a model ID string. Returns [Custom] for unrecognized models. *)
val of_model_id : string -> known_model

(** Get the capabilities of a model. [Custom] models get conservative defaults. *)
val capabilities : known_model -> model_capabilities

(** Default max output tokens for a model. *)
val default_max_tokens : known_model -> int
