(* Content blocks *)

type text_block = { text : string } [@@deriving yojson { strict = false }]

type thinking_block = {
  thinking : string;
  signature : string;
}
[@@deriving yojson { strict = false }]

type tool_use_block = {
  id : string;
  name : string;
  input : Yojson.Safe.t; [@to_yojson fun x -> x] [@of_yojson fun x -> Ok x]
}
[@@deriving yojson { strict = false }]

type tool_result_block = {
  tool_use_id : string;
  content : string;
  is_error : bool; [@default false]
}
[@@deriving yojson { strict = false }]

type content_block =
  | Text of text_block
  | Thinking of thinking_block
  | Tool_use of tool_use_block
  | Tool_result of tool_result_block

let add_type_field type_name json =
  match json with
  | `Assoc fields -> `Assoc (("type", `String type_name) :: fields)
  | other -> other

let content_block_to_yojson = function
  | Text b -> add_type_field "text" (text_block_to_yojson b)
  | Thinking b -> add_type_field "thinking" (thinking_block_to_yojson b)
  | Tool_use b -> add_type_field "tool_use" (tool_use_block_to_yojson b)
  | Tool_result b -> add_type_field "tool_result" (tool_result_block_to_yojson b)

let content_block_of_yojson json =
  match Yojson.Safe.Util.(member "type" json |> to_string) with
  | "text" -> text_block_of_yojson json |> Result.map (fun b -> Text b)
  | "thinking" -> thinking_block_of_yojson json |> Result.map (fun b -> Thinking b)
  | "tool_use" -> tool_use_block_of_yojson json |> Result.map (fun b -> Tool_use b)
  | "tool_result" -> tool_result_block_of_yojson json |> Result.map (fun b -> Tool_result b)
  | other -> Error ("unknown content block type: " ^ other)
  | exception _ -> Error "missing type field in content block"

(* Usage *)

type usage = {
  input_tokens : int; [@default 0]
  output_tokens : int; [@default 0]
  cache_read_input_tokens : int; [@default 0]
  cache_creation_input_tokens : int; [@default 0]
}
[@@deriving yojson { strict = false }]

(* API message (nested inside assistant messages) *)

type api_message = {
  id : string;
  model : string;
  role : string;
  content : content_block list;
  stop_reason : string option; [@default None]
  usage : usage;
}
[@@deriving yojson { strict = false }]

(* Top-level message types *)

type system_message = {
  subtype : string;
  session_id : string option; [@default None]
  cwd : string option; [@default None]
  tools : string list; [@default []]
  model : string option; [@default None]
  permission_mode : string option; [@default None] [@key "permissionMode"]
  claude_code_version : string option; [@default None]
  uuid : string option; [@default None]
}
[@@deriving yojson { strict = false }]

type assistant_message = {
  message : api_message;
  parent_tool_use_id : string option; [@default None]
  session_id : string option; [@default None]
  uuid : string option; [@default None]
}
[@@deriving yojson { strict = false }]

type result_message = {
  subtype : string;
  is_error : bool; [@default false]
  duration_ms : float option; [@default None]
  duration_api_ms : float option; [@default None]
  num_turns : int option; [@default None]
  session_id : string option; [@default None]
  total_cost_usd : float option; [@default None]
  result : string option; [@default None]
  uuid : string option; [@default None]
}
[@@deriving yojson { strict = false }]

type user_message = {
  content : Yojson.Safe.t; [@to_yojson fun x -> x] [@of_yojson fun x -> Ok x]
  uuid : string option; [@default None]
  parent_tool_use_id : string option; [@default None]
}
[@@deriving yojson { strict = false }]

(* Control protocol types *)

type control_request = {
  request_id : string;
  request : Yojson.Safe.t; [@to_yojson fun x -> x] [@of_yojson fun x -> Ok x]
}
[@@deriving yojson { strict = false }]

type control_response = {
  request_id : string;
  error : string option; [@default None]
  result : Yojson.Safe.t option;
     [@default None]
     [@to_yojson
       fun x ->
         match x with
         | None -> `Null
         | Some v -> v]
     [@of_yojson
       fun x ->
         match x with
         | `Null -> Ok None
         | v -> Ok (Some v)]
}
[@@deriving yojson { strict = false }]

(* Configuration types *)

type agent_definition = {
  description : string;
  prompt : string option; [@default None]
  tools : string list option; [@default None]
  model : string option; [@default None]
}
[@@deriving yojson]

type mcp_stdio_server = {
  command : string;
  args : string list;
  env : (string * string) list option; [@default None]
}
[@@deriving yojson]
