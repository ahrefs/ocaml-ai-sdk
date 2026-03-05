(** Agent configuration options. *)

type permission_mode =
  | Default
  | Accept_edits
  | Plan
  | Bypass_permissions

val pp_permission_mode : Format.formatter -> permission_mode -> unit
val show_permission_mode : permission_mode -> string
val permission_mode_to_string : permission_mode -> string

type t = {
  system_prompt : string option;
  append_system_prompt : string option;
  allowed_tools : string list option;
  disallowed_tools : string list option;
  permission_mode : permission_mode option;
  cwd : string option;
  max_turns : int option;
  max_budget_usd : float option;
  model : string option;
  cli_path : string option;
  resume : string option;
  continue_conversation : bool option;
  env : (string * string) list option;
  agents : (string * Types.agent_definition) list option;
  mcp_servers : (string * Yojson.Safe.t) list option;
}

(** All fields [None]. *)
val default : t
