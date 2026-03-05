(** Unified input options for both generate and stream calls. *)

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

(** Create call options with sensible defaults. Only [prompt] is required. *)
val default : prompt:Prompt.message list -> t
