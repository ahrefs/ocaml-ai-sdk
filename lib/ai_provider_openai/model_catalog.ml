type system_message_mode =
  | System
  | Developer
  | Remove

type model_capabilities = {
  is_reasoning_model : bool;
  system_message_mode : system_message_mode;
  default_max_tokens : int;
  supports_structured_output : bool;
  supports_vision : bool;
  supports_tool_calling : bool;
}

type known_model =
  | Gpt_4_1
  | Gpt_4_1_mini
  | Gpt_4_1_nano
  | Gpt_4o
  | Gpt_4o_mini
  | Gpt_4_turbo
  | Gpt_4
  | Gpt_3_5_turbo
  | O1
  | O1_mini
  | O3
  | O3_mini
  | O4_mini
  | Custom of string

let to_model_id = function
  | Gpt_4_1 -> "gpt-4.1"
  | Gpt_4_1_mini -> "gpt-4.1-mini"
  | Gpt_4_1_nano -> "gpt-4.1-nano"
  | Gpt_4o -> "gpt-4o"
  | Gpt_4o_mini -> "gpt-4o-mini"
  | Gpt_4_turbo -> "gpt-4-turbo"
  | Gpt_4 -> "gpt-4"
  | Gpt_3_5_turbo -> "gpt-3.5-turbo"
  | O1 -> "o1"
  | O1_mini -> "o1-mini"
  | O3 -> "o3"
  | O3_mini -> "o3-mini"
  | O4_mini -> "o4-mini"
  | Custom s -> s

let of_model_id s =
  match s with
  | "gpt-4.1" -> Gpt_4_1
  | "gpt-4.1-mini" -> Gpt_4_1_mini
  | "gpt-4.1-nano" -> Gpt_4_1_nano
  | "gpt-4o" -> Gpt_4o
  | "gpt-4o-mini" -> Gpt_4o_mini
  | "gpt-4-turbo" -> Gpt_4_turbo
  | "gpt-4" -> Gpt_4
  | "gpt-3.5-turbo" -> Gpt_3_5_turbo
  | "o1" -> O1
  | "o1-mini" -> O1_mini
  | "o3" -> O3
  | "o3-mini" -> O3_mini
  | "o4-mini" -> O4_mini
  | s -> Custom s

let standard_capabilities =
  {
    is_reasoning_model = false;
    system_message_mode = System;
    default_max_tokens = 4096;
    supports_structured_output = true;
    supports_vision = true;
    supports_tool_calling = true;
  }

let reasoning_capabilities =
  {
    is_reasoning_model = true;
    system_message_mode = Developer;
    default_max_tokens = 100_000;
    supports_structured_output = true;
    supports_vision = true;
    supports_tool_calling = true;
  }

let capabilities model_id =
  match of_model_id model_id with
  | O1 | O1_mini | O3 | O3_mini | O4_mini -> reasoning_capabilities
  | Gpt_4_1 | Gpt_4_1_mini -> { standard_capabilities with default_max_tokens = 32_768 }
  | Gpt_4_1_nano -> { standard_capabilities with default_max_tokens = 16_384 }
  | Gpt_4o | Gpt_4o_mini -> { standard_capabilities with default_max_tokens = 16_384 }
  | Gpt_4_turbo -> standard_capabilities
  | Gpt_4 -> { standard_capabilities with supports_vision = false }
  | Gpt_3_5_turbo -> { standard_capabilities with supports_vision = false; supports_structured_output = false }
  | Custom s ->
    (* For dated variants like "gpt-4o-2024-08-06", check prefix *)
    let is_prefix p = String.starts_with ~prefix:p s in
    (match is_prefix "o1", is_prefix "o3", is_prefix "o4" with
    | true, _, _ | _, true, _ | _, _, true -> reasoning_capabilities
    | false, false, false ->
    match is_prefix "gpt-4.1", is_prefix "gpt-4o" with
    | true, _ -> { standard_capabilities with default_max_tokens = 32_768 }
    | false, true -> { standard_capabilities with default_max_tokens = 16_384 }
    | false, false -> standard_capabilities)

let is_reasoning_model model_id = (capabilities model_id).is_reasoning_model
