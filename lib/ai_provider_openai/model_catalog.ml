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
  supports_non_reasoning_parameters : bool;
}

type known_model =
  | Gpt_6_1_sol
  | Gpt_6_1_terra
  | Gpt_6_astra
  | Gpt_6_luna
  | Gpt_6_sol
  | Gpt_5_6
  | Gpt_5_6_luna
  | Gpt_5_6_sol
  | Gpt_5_6_terra
  | Gpt_5_5
  | Gpt_5_4
  | Gpt_5_4_mini
  | Gpt_5_4_nano
  | Gpt_5_2
  | Gpt_5_1
  | Gpt_5_1_chat_latest
  | Gpt_5
  | Gpt_5_mini
  | Gpt_5_nano
  | Gpt_5_chat_latest
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
  | Gpt_6_1_sol -> "gpt-6.1-sol"
  | Gpt_6_1_terra -> "gpt-6.1-terra"
  | Gpt_6_astra -> "gpt-6-astra"
  | Gpt_6_luna -> "gpt-6-luna"
  | Gpt_6_sol -> "gpt-6-sol"
  | Gpt_5_6 -> "gpt-5.6"
  | Gpt_5_6_luna -> "gpt-5.6-luna"
  | Gpt_5_6_sol -> "gpt-5.6-sol"
  | Gpt_5_6_terra -> "gpt-5.6-terra"
  | Gpt_5_5 -> "gpt-5.5"
  | Gpt_5_4 -> "gpt-5.4"
  | Gpt_5_4_mini -> "gpt-5.4-mini"
  | Gpt_5_4_nano -> "gpt-5.4-nano"
  | Gpt_5_2 -> "gpt-5.2"
  | Gpt_5_1 -> "gpt-5.1"
  | Gpt_5_1_chat_latest -> "gpt-5.1-chat-latest"
  | Gpt_5 -> "gpt-5"
  | Gpt_5_mini -> "gpt-5-mini"
  | Gpt_5_nano -> "gpt-5-nano"
  | Gpt_5_chat_latest -> "gpt-5-chat-latest"
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
  | "gpt-6.1-sol" -> Gpt_6_1_sol
  | "gpt-6.1-terra" -> Gpt_6_1_terra
  | "gpt-6-astra" -> Gpt_6_astra
  | "gpt-6-luna" -> Gpt_6_luna
  | "gpt-6-sol" -> Gpt_6_sol
  | "gpt-5.6" -> Gpt_5_6
  | "gpt-5.6-luna" -> Gpt_5_6_luna
  | "gpt-5.6-sol" -> Gpt_5_6_sol
  | "gpt-5.6-terra" -> Gpt_5_6_terra
  | "gpt-5.5" -> Gpt_5_5
  | "gpt-5.4" -> Gpt_5_4
  | "gpt-5.4-mini" -> Gpt_5_4_mini
  | "gpt-5.4-nano" -> Gpt_5_4_nano
  | "gpt-5.2" -> Gpt_5_2
  | "gpt-5.1" -> Gpt_5_1
  | "gpt-5.1-chat-latest" -> Gpt_5_1_chat_latest
  | "gpt-5" -> Gpt_5
  | "gpt-5-mini" -> Gpt_5_mini
  | "gpt-5-nano" -> Gpt_5_nano
  | "gpt-5-chat-latest" -> Gpt_5_chat_latest
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
    supports_non_reasoning_parameters = false;
  }

let reasoning_capabilities =
  {
    is_reasoning_model = true;
    system_message_mode = Developer;
    default_max_tokens = 100_000;
    supports_structured_output = true;
    supports_vision = true;
    supports_tool_calling = true;
    supports_non_reasoning_parameters = false;
  }

(* A non-empty run of ASCII digits, as the regex [\d+]. *)
let is_digits s = (not (String.equal s "")) && String.for_all Char.Ascii.is_digit s

(* [s] up to its first "-", and the rest after it if there is a "-". *)
let split_at_dash s =
  match String.index_opt s '-' with
  | None -> s, None
  | Some i -> String.sub s 0 i, Some (String.sub s (i + 1) (String.length s - i - 1))

(* "o<digits>", alone or followed by "-": the o-series reasoning models. *)
let is_o_series s =
  let head, _ = split_at_dash s in
  String.starts_with ~prefix:"o" head && is_digits (String.sub head 1 (String.length head - 1))

type gpt_version = {
  major : int;
  minor : int option;
  variant : string option;
}

(* Parses "gpt-<major>[.<minor>][-<variant>]", as upstream's getGptVersion. *)
let gpt_version s =
  let number s =
    match is_digits s with
    | true -> int_of_string_opt s
    | false -> None
  in
  match String.starts_with ~prefix:"gpt-" s with
  | false -> None
  | true ->
    let version, variant = split_at_dash (String.sub s 4 (String.length s - 4)) in
    (match String.split_on_char '.' version, variant with
    | _, Some "" -> None
    | [ major ], _ -> Option.map (fun major -> { major; minor = None; variant }) (number major)
    | [ major; minor ], _ ->
      Option.bind (number major) (fun major ->
        Option.map (fun minor -> { major; minor = Some minor; variant }) (number minor))
    | ([] | _ :: _ :: _ :: _), _ -> None)

(* Matches upstream's getOpenAILanguageModelCapabilities: o-series models and
   GPT-5 or later are reasoning models, except a GPT chat variant without a
   minor version (e.g. "gpt-5-chat-latest"). Other IDs fall back to prefixes
   for dated variants like "gpt-4o-2024-08-06". *)
let inferred_capabilities s =
  match is_o_series s, gpt_version s with
  | true, _ -> reasoning_capabilities
  | false, Some { major; minor = None; variant = Some variant }
    when major >= 5 && String.starts_with ~prefix:"chat" variant ->
    { standard_capabilities with default_max_tokens = 16_384 }
  | false, Some { major; minor; _ } when major >= 5 ->
    (* GPT-5.1 and later 5.x models accept sampling parameters when the
       reasoning effort is none; GPT-6 does not. *)
    {
      reasoning_capabilities with
      supports_non_reasoning_parameters = Int.equal major 5 && Option.value minor ~default:0 >= 1;
    }
  | false, (Some _ | None) ->
  match String.starts_with ~prefix:"gpt-4.1" s, String.starts_with ~prefix:"gpt-4o" s with
  | true, _ -> { standard_capabilities with default_max_tokens = 32_768 }
  | false, true -> { standard_capabilities with default_max_tokens = 16_384 }
  | false, false -> standard_capabilities

let capabilities model_id =
  match of_model_id model_id with
  | O1 | O1_mini | O3 | O3_mini | O4_mini -> reasoning_capabilities
  | Gpt_4_1 | Gpt_4_1_mini -> { standard_capabilities with default_max_tokens = 32_768 }
  | Gpt_4_1_nano -> { standard_capabilities with default_max_tokens = 16_384 }
  | Gpt_4o | Gpt_4o_mini -> { standard_capabilities with default_max_tokens = 16_384 }
  | Gpt_4_turbo -> standard_capabilities
  | Gpt_4 -> { standard_capabilities with supports_vision = false }
  | Gpt_3_5_turbo -> { standard_capabilities with supports_vision = false; supports_structured_output = false }
  | Gpt_6_1_sol | Gpt_6_1_terra | Gpt_6_astra | Gpt_6_luna | Gpt_6_sol | Gpt_5_6 | Gpt_5_6_luna | Gpt_5_6_sol
  | Gpt_5_6_terra | Gpt_5_5 | Gpt_5_4 | Gpt_5_4_mini | Gpt_5_4_nano | Gpt_5_2 | Gpt_5_1 | Gpt_5_1_chat_latest | Gpt_5
  | Gpt_5_mini | Gpt_5_nano | Gpt_5_chat_latest | Custom _ ->
    inferred_capabilities model_id

let is_reasoning_model model_id = (capabilities model_id).is_reasoning_model
