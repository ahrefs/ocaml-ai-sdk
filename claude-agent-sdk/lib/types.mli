(** JSON wire types for the Claude Code CLI streaming protocol. *)

(** {1 Content blocks} *)

type text_block = { text : string }
type thinking_block = {
  thinking : string;
  signature : string;
}

type tool_use_block = {
  id : string;
  name : string;
  input : Yojson.Safe.t;
}

type tool_result_block = {
  tool_use_id : string;
  content : string;
  is_error : bool;
}

type content_block =
  | Text of text_block
  | Thinking of thinking_block
  | Tool_use of tool_use_block
  | Tool_result of tool_result_block

val content_block_of_yojson : Yojson.Safe.t -> (content_block, string) result

val content_block_to_yojson : content_block -> Yojson.Safe.t

(** {1 Usage} *)

type usage = {
  input_tokens : int;
  output_tokens : int;
  cache_read_input_tokens : int;
  cache_creation_input_tokens : int;
}

val usage_of_yojson : Yojson.Safe.t -> (usage, string) result
val usage_to_yojson : usage -> Yojson.Safe.t

(** {1 API message} *)

type api_message = {
  id : string;
  model : string;
  role : string;
  content : content_block list;
  stop_reason : string option;
  usage : usage;
}

val api_message_of_yojson : Yojson.Safe.t -> (api_message, string) result
val api_message_to_yojson : api_message -> Yojson.Safe.t

(** {1 Top-level message types} *)

type system_message = {
  subtype : string;
  session_id : string option;
  cwd : string option;
  tools : string list;
  model : string option;
  permission_mode : string option;
  claude_code_version : string option;
  uuid : string option;
}

val system_message_of_yojson : Yojson.Safe.t -> (system_message, string) result

val system_message_to_yojson : system_message -> Yojson.Safe.t

type assistant_message = {
  message : api_message;
  parent_tool_use_id : string option;
  session_id : string option;
  uuid : string option;
}

val assistant_message_of_yojson : Yojson.Safe.t -> (assistant_message, string) result

val assistant_message_to_yojson : assistant_message -> Yojson.Safe.t

type result_message = {
  subtype : string;
  is_error : bool;
  duration_ms : float option;
  duration_api_ms : float option;
  num_turns : int option;
  session_id : string option;
  total_cost_usd : float option;
  result : string option;
  uuid : string option;
}

val result_message_of_yojson : Yojson.Safe.t -> (result_message, string) result

val result_message_to_yojson : result_message -> Yojson.Safe.t

type user_message = {
  content : Yojson.Safe.t;
  uuid : string option;
  parent_tool_use_id : string option;
}

val user_message_of_yojson : Yojson.Safe.t -> (user_message, string) result

val user_message_to_yojson : user_message -> Yojson.Safe.t

(** {1 Control protocol} *)

type control_request = {
  request_id : string;
  request : Yojson.Safe.t;
}

val control_request_of_yojson : Yojson.Safe.t -> (control_request, string) result

val control_request_to_yojson : control_request -> Yojson.Safe.t

type control_response = {
  request_id : string;
  error : string option;
  result : Yojson.Safe.t option;
}

val control_response_of_yojson : Yojson.Safe.t -> (control_response, string) result

val control_response_to_yojson : control_response -> Yojson.Safe.t

(** {1 Configuration types} *)

type agent_definition = {
  description : string;
  prompt : string option;
  tools : string list option;
  model : string option;
}

val agent_definition_of_yojson : Yojson.Safe.t -> (agent_definition, string) result

val agent_definition_to_yojson : agent_definition -> Yojson.Safe.t

type mcp_stdio_server = {
  command : string;
  args : string list;
  env : (string * string) list option;
}

val mcp_stdio_server_of_yojson : Yojson.Safe.t -> (mcp_stdio_server, string) result

val mcp_stdio_server_to_yojson : mcp_stdio_server -> Yojson.Safe.t
