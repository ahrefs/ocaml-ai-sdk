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
  | Claude_opus_4_7
  | Claude_opus_4_6
  | Claude_sonnet_4_6
  | Custom of string

let to_model_id = function
  | Claude_fable_5 -> "claude-fable-5"
  | Claude_mythos_5 -> "claude-mythos-5"
  | Claude_opus_5 -> "claude-opus-5"
  | Claude_opus_4_8 -> "claude-opus-4-8"
  | Claude_sonnet_5 -> "claude-sonnet-5"
  | Claude_opus_4_7 -> "claude-opus-4-7"
  | Claude_opus_4_6 -> "claude-opus-4-6"
  | Claude_sonnet_4_6 -> "claude-sonnet-4-6"
  | Custom s -> s

let of_model_id = function
  | "claude-fable-5" -> Claude_fable_5
  | "claude-mythos-5" -> Claude_mythos_5
  | "claude-opus-5" -> Claude_opus_5
  | "claude-opus-4-8" -> Claude_opus_4_8
  | "claude-sonnet-5" -> Claude_sonnet_5
  | "claude-opus-4-7" -> Claude_opus_4_7
  | "claude-opus-4-6" -> Claude_opus_4_6
  | "claude-sonnet-4-6" -> Claude_sonnet_4_6
  | s -> Custom s

let all_effort_levels = [ Effort.Low; Effort.Medium; Effort.High; Effort.Xhigh; Effort.Max ]

let effort_without_xhigh = [ Effort.Low; Effort.Medium; Effort.High; Effort.Max ]
let capabilities = function
  | Claude_fable_5 ->
    {
      max_output_tokens = 128_000;
      thinking =
        Some
          {
            manual = false;
            adaptive = true;
            defaults_to_adaptive = true;
            disabled = Unsupported;
            effort_levels = all_effort_levels;
            display_default = Some Thinking.Omitted;
          };
      rejects_sampling_parameters = true;
      supports_structured_output = true;
      supports_prompt_caching = true;
      min_cache_tokens = 512;
      supports_vision = true;
      supports_pdf = true;
    }
  | Claude_mythos_5 ->
    {
      max_output_tokens = 128_000;
      thinking =
        Some
          {
            manual = false;
            adaptive = true;
            defaults_to_adaptive = true;
            disabled = Unsupported;
            effort_levels = all_effort_levels;
            display_default = Some Thinking.Omitted;
          };
      rejects_sampling_parameters = true;
      supports_structured_output = true;
      supports_prompt_caching = true;
      min_cache_tokens = 512;
      supports_vision = true;
      supports_pdf = true;
    }
  | Claude_opus_5 ->
    {
      max_output_tokens = 128_000;
      thinking =
        Some
          {
            manual = false;
            adaptive = true;
            defaults_to_adaptive = true;
            disabled = Up_to_high;
            effort_levels = all_effort_levels;
            display_default = Some Thinking.Omitted;
          };
      rejects_sampling_parameters = true;
      supports_structured_output = true;
      supports_prompt_caching = true;
      min_cache_tokens = 512;
      supports_vision = true;
      supports_pdf = true;
    }
  | Claude_opus_4_8 ->
    {
      max_output_tokens = 128_000;
      thinking =
        Some
          {
            manual = false;
            adaptive = true;
            defaults_to_adaptive = false;
            disabled = Allowed;
            effort_levels = all_effort_levels;
            display_default = Some Thinking.Omitted;
          };
      rejects_sampling_parameters = true;
      supports_structured_output = true;
      supports_prompt_caching = true;
      min_cache_tokens = 1024;
      supports_vision = true;
      supports_pdf = true;
    }
  | Claude_sonnet_5 ->
    {
      max_output_tokens = 128_000;
      thinking =
        Some
          {
            manual = false;
            adaptive = true;
            defaults_to_adaptive = true;
            disabled = Allowed;
            effort_levels = all_effort_levels;
            display_default = Some Thinking.Omitted;
          };
      rejects_sampling_parameters = true;
      supports_structured_output = true;
      supports_prompt_caching = true;
      min_cache_tokens = 1024;
      supports_vision = true;
      supports_pdf = true;
    }
  | Claude_opus_4_7 ->
    {
      max_output_tokens = 128_000;
      thinking =
        Some
          {
            manual = false;
            adaptive = true;
            defaults_to_adaptive = false;
            disabled = Allowed;
            effort_levels = all_effort_levels;
            display_default = Some Thinking.Omitted;
          };
      rejects_sampling_parameters = true;
      supports_structured_output = true;
      supports_prompt_caching = true;
      min_cache_tokens = 2048;
      supports_vision = true;
      supports_pdf = true;
    }
  | Claude_opus_4_6 ->
    {
      max_output_tokens = 128_000;
      thinking =
        Some
          {
            manual = true;
            adaptive = true;
            defaults_to_adaptive = false;
            disabled = Allowed;
            effort_levels = effort_without_xhigh;
            display_default = Some Thinking.Summarized;
          };
      rejects_sampling_parameters = false;
      supports_structured_output = true;
      supports_prompt_caching = true;
      min_cache_tokens = 4096;
      supports_vision = true;
      supports_pdf = true;
    }
  | Claude_sonnet_4_6 ->
    {
      max_output_tokens = 128_000;
      thinking =
        Some
          {
            manual = true;
            adaptive = true;
            defaults_to_adaptive = false;
            disabled = Allowed;
            effort_levels = effort_without_xhigh;
            display_default = Some Thinking.Summarized;
          };
      rejects_sampling_parameters = false;
      supports_structured_output = true;
      supports_prompt_caching = true;
      min_cache_tokens = 1024;
      supports_vision = true;
      supports_pdf = true;
    }
  | Custom _ ->
    {
      max_output_tokens = 4096;
      thinking = None;
      rejects_sampling_parameters = false;
      supports_structured_output = false;
      supports_prompt_caching = false;
      min_cache_tokens = 4096;
      supports_vision = false;
      supports_pdf = false;
    }

let default_max_tokens model = (capabilities model).max_output_tokens
