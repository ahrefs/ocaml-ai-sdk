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
  | Claude_opus_4_7
  | Claude_opus_4_6
  | Claude_sonnet_4_6
  | Claude_haiku_4_5
  | Claude_sonnet_4_5
  | Claude_opus_4_5
  | Claude_opus_4_1
  | Claude_sonnet_4
  | Claude_opus_4
  | Custom of string

let to_model_id = function
  | Claude_opus_4_7 -> "claude-opus-4-7"
  | Claude_opus_4_6 -> "claude-opus-4-6"
  | Claude_sonnet_4_6 -> "claude-sonnet-4-6"
  | Claude_haiku_4_5 -> "claude-haiku-4-5-20251001"
  | Claude_sonnet_4_5 -> "claude-sonnet-4-5-20250929"
  | Claude_opus_4_5 -> "claude-opus-4-5-20251101"
  | Claude_opus_4_1 -> "claude-opus-4-1-20250805"
  | Claude_sonnet_4 -> "claude-sonnet-4-20250514"
  | Claude_opus_4 -> "claude-opus-4-20250514"
  | Custom s -> s

let of_model_id s =
  match s with
  (* Current generation *)
  | "claude-opus-4-7" -> Claude_opus_4_7
  | "claude-opus-4-6" -> Claude_opus_4_6
  | "claude-sonnet-4-6" -> Claude_sonnet_4_6
  | "claude-haiku-4-5-20251001" | "claude-haiku-4-5" -> Claude_haiku_4_5
  (* Legacy *)
  | "claude-sonnet-4-5-20250929" | "claude-sonnet-4-5" -> Claude_sonnet_4_5
  | "claude-opus-4-5-20251101" | "claude-opus-4-5" -> Claude_opus_4_5
  | "claude-opus-4-1-20250805" | "claude-opus-4-1" -> Claude_opus_4_1
  | "claude-sonnet-4-20250514" | "claude-sonnet-4-0" -> Claude_sonnet_4
  | "claude-opus-4-20250514" | "claude-opus-4-0" -> Claude_opus_4
  (* Unknown *)
  | s -> Custom s

(* Structured outputs (output_config.format = json_schema) is GA on Haiku 4.5+, Sonnet 4.5+,
   Opus 4.5+. Not supported on Sonnet 4.0, Opus 4.0, Opus 4.1, or unknown models. *)
let base_capabilities =
  {
    max_output_tokens = 64_000;
    supports_thinking = true;
    supports_structured_output = false;
    supports_prompt_caching = true;
    min_cache_tokens = 1024;
    supports_vision = true;
    supports_pdf = true;
  }

let capabilities = function
  | Claude_opus_4_7 -> { base_capabilities with max_output_tokens = 128_000; supports_structured_output = true }
  | Claude_opus_4_6 -> { base_capabilities with max_output_tokens = 128_000; supports_structured_output = true }
  | Claude_sonnet_4_6 | Claude_sonnet_4_5 -> { base_capabilities with supports_structured_output = true }
  | Claude_sonnet_4 -> base_capabilities
  | Claude_haiku_4_5 | Claude_opus_4_5 ->
    { base_capabilities with min_cache_tokens = 4096; supports_structured_output = true }
  | Claude_opus_4_1 | Claude_opus_4 -> { base_capabilities with max_output_tokens = 32_000 }
  | Custom _ ->
    {
      max_output_tokens = 4096;
      supports_thinking = false;
      supports_structured_output = false;
      supports_prompt_caching = false;
      min_cache_tokens = 4096;
      supports_vision = false;
      supports_pdf = false;
    }

let default_max_tokens model = (capabilities model).max_output_tokens
