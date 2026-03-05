type permission_mode =
  | Default
  | Accept_edits
  | Plan
  | Bypass_permissions
[@@deriving show]

let permission_mode_to_string = function
  | Default -> "default"
  | Accept_edits -> "acceptEdits"
  | Plan -> "plan"
  | Bypass_permissions -> "bypassPermissions"

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

let default =
  {
    system_prompt = None;
    append_system_prompt = None;
    allowed_tools = None;
    disallowed_tools = None;
    permission_mode = None;
    cwd = None;
    max_turns = None;
    max_budget_usd = None;
    model = None;
    cli_path = None;
    resume = None;
    continue_conversation = None;
    env = None;
    agents = None;
    mcp_servers = None;
  }
