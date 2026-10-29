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
  between_tools : bool;
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
  rejects_forced_tool_choice : bool;
}

type known_model =
  | Claude_fable_5_1
  | Claude_fable_5
  | Claude_mythos_5_1
  | Claude_mythos_5
  | Claude_opus_5_5
  | Claude_opus_5
  | Claude_opus_4_8
  | Claude_sonnet_5_5
  | Claude_sonnet_5
  | Claude_haiku_5_5
  | Claude_haiku_4_5
  | Custom of string

let to_model_id = function
  | Claude_fable_5_1 -> "claude-fable-5-1"
  | Claude_fable_5 -> "claude-fable-5"
  | Claude_mythos_5_1 -> "claude-mythos-5-1"
  | Claude_mythos_5 -> "claude-mythos-5"
  | Claude_opus_5_5 -> "claude-opus-5-5"
  | Claude_opus_5 -> "claude-opus-5"
  | Claude_opus_4_8 -> "claude-opus-4-8"
  | Claude_sonnet_5_5 -> "claude-sonnet-5-5"
  | Claude_sonnet_5 -> "claude-sonnet-5"
  | Claude_haiku_5_5 -> "claude-haiku-5-5"
  | Claude_haiku_4_5 -> "claude-haiku-4-5-20251001"
  | Custom s -> s

let of_model_id = function
  | "claude-fable-5-1" -> Claude_fable_5_1
  | "claude-fable-5" -> Claude_fable_5
  | "claude-mythos-5-1" -> Claude_mythos_5_1
  | "claude-mythos-5" -> Claude_mythos_5
  | "claude-opus-5-5" -> Claude_opus_5_5
  | "claude-opus-5" -> Claude_opus_5
  | "claude-opus-4-8" -> Claude_opus_4_8
  | "claude-sonnet-5-5" -> Claude_sonnet_5_5
  | "claude-sonnet-5" -> Claude_sonnet_5
  | "claude-haiku-5-5" -> Claude_haiku_5_5
  | "claude-haiku-4-5-20251001" | "claude-haiku-4-5" -> Claude_haiku_4_5
  | s -> Custom s

let all_effort_levels = [ Effort.Low; Effort.Medium; Effort.High; Effort.Xhigh; Effort.Max ]

(* Thinking on the adaptive generation: no manual budgets, every effort level,
   thinking text omitted by default. *)
let adaptive_thinking ?(between_tools = false) ~defaults_to_adaptive disabled =
  Some
    {
      manual = false;
      adaptive = true;
      defaults_to_adaptive;
      disabled;
      effort_levels = all_effort_levels;
      display_default = Some Thinking.Omitted;
      between_tools;
    }

(* The adaptive generation: 128k output, no sampling parameters, native
   structured output, vision and PDF. *)
let adaptive_model ?(rejects_forced_tool_choice = false) ~min_cache_tokens thinking =
  {
    max_output_tokens = 128_000;
    thinking;
    rejects_sampling_parameters = true;
    supports_structured_output = true;
    supports_prompt_caching = true;
    min_cache_tokens;
    supports_vision = true;
    supports_pdf = true;
    rejects_forced_tool_choice;
  }

let capabilities = function
  | Claude_fable_5_1 | Claude_mythos_5_1 ->
    adaptive_model ~rejects_forced_tool_choice:true ~min_cache_tokens:512
      (adaptive_thinking ~defaults_to_adaptive:true Unsupported)
  | Claude_fable_5 | Claude_mythos_5 ->
    adaptive_model ~min_cache_tokens:512 (adaptive_thinking ~defaults_to_adaptive:true Unsupported)
  | Claude_opus_5_5 ->
    adaptive_model ~rejects_forced_tool_choice:true ~min_cache_tokens:512
      (adaptive_thinking ~defaults_to_adaptive:true Unsupported)
  | Claude_opus_5 -> adaptive_model ~min_cache_tokens:512 (adaptive_thinking ~defaults_to_adaptive:true Up_to_high)
  | Claude_opus_4_8 -> adaptive_model ~min_cache_tokens:1024 (adaptive_thinking ~defaults_to_adaptive:false Allowed)
  | Claude_sonnet_5_5 ->
    adaptive_model ~rejects_forced_tool_choice:true ~min_cache_tokens:512
      (adaptive_thinking ~between_tools:true ~defaults_to_adaptive:true Unsupported)
  | Claude_sonnet_5 -> adaptive_model ~min_cache_tokens:1024 (adaptive_thinking ~defaults_to_adaptive:true Allowed)
  | Claude_haiku_5_5 -> adaptive_model ~min_cache_tokens:512 (adaptive_thinking ~defaults_to_adaptive:true Up_to_high)
  | Claude_haiku_4_5 ->
    (* Pre-adaptive model: manual budgeted thinking only, no effort levels.
       See docs/plans/2026-08-03-adaptive-thinking-support.md. *)
    {
      max_output_tokens = 64_000;
      thinking =
        Some
          {
            manual = true;
            adaptive = false;
            defaults_to_adaptive = false;
            disabled = Allowed;
            effort_levels = [];
            display_default = Some Thinking.Summarized;
            between_tools = false;
          };
      rejects_sampling_parameters = false;
      supports_structured_output = true;
      supports_prompt_caching = true;
      min_cache_tokens = 4096;
      supports_vision = true;
      supports_pdf = true;
      rejects_forced_tool_choice = false;
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
      rejects_forced_tool_choice = false;
    }

let default_max_tokens model = (capabilities model).max_output_tokens
