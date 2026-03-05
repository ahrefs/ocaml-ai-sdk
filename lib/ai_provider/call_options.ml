type t = {
  prompt : Prompt.message list;
  mode : Mode.t;
  tools : Tool.t list;
  tool_choice : Tool_choice.t option;
  max_output_tokens : int option;
  temperature : float option;
  top_p : float option;
  top_k : int option;
  stop_sequences : string list;
  seed : int option;
  frequency_penalty : float option;
  presence_penalty : float option;
  provider_options : Provider_options.t;
  headers : (string * string) list;
  abort_signal : unit Lwt.t option;
}

let default ~prompt =
  {
    prompt;
    mode = Mode.Regular;
    tools = [];
    tool_choice = None;
    max_output_tokens = None;
    temperature = None;
    top_p = None;
    top_k = None;
    stop_sequences = [];
    seed = None;
    frequency_penalty = None;
    presence_penalty = None;
    provider_options = Provider_options.empty;
    headers = [];
    abort_signal = None;
  }
