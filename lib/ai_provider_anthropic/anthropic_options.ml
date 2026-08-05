type structured_output_mode =
  | Auto
  | Output_format
  | Json_tool

type t = {
  thinking : Thinking.t option;
  effort : Effort.t option;
  tool_streaming : bool;
  structured_output_mode : structured_output_mode;
}

let default = { thinking = None; effort = None; tool_streaming = true; structured_output_mode = Auto }

type _ Ai_provider.Provider_options.key += Anthropic : t Ai_provider.Provider_options.key

let to_provider_options opts = Ai_provider.Provider_options.set Anthropic opts Ai_provider.Provider_options.empty

let of_provider_options opts = Ai_provider.Provider_options.find Anthropic opts
