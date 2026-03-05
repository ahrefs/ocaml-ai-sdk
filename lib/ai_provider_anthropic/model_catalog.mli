(** Known Anthropic models with capabilities metadata. *)

type model_capabilities = {
  max_output_tokens : int;
  supports_thinking : bool;
  supports_structured_output : bool;
  supports_prompt_caching : bool;
  min_cache_tokens : int;
  supports_vision : bool;
  supports_pdf : bool;
}

type known_model =
  | Claude_opus_4_6
  | Claude_sonnet_4_6
  | Claude_haiku_4_5
  | Claude_sonnet_4_5
  | Claude_opus_4_5
  | Claude_opus_4_1
  | Claude_sonnet_4
  | Claude_opus_4
  | Custom of string

(** Convert a known model to its API model ID string. *)
val to_model_id : known_model -> string

(** Parse a model ID string. Returns [Custom] for unrecognized models.
    Accepts both dated versions and aliases. *)
val of_model_id : string -> known_model

(** Get the capabilities of a model. [Custom] models get conservative defaults. *)
val capabilities : known_model -> model_capabilities

(** Default max output tokens for a model. *)
val default_max_tokens : known_model -> int
