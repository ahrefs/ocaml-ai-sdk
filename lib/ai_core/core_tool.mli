(** Tool definition for the Core SDK.

    Tools have a description, JSON Schema parameters, and an optional execute
    function. Tools with no [execute] are client-side tools — the frontend
    provides results via [addToolOutput]. Tools can optionally require approval
    before execution via [needs_approval]. *)

type t = {
  description : string option;
  parameters : Yojson.Basic.t;  (** JSON Schema for tool parameters *)
  execute : (Yojson.Basic.t -> Yojson.Basic.t Lwt.t) option;
    (** Execute the tool server-side. [None] for client-side tools
        where the frontend provides results. *)
  needs_approval : (Yojson.Basic.t -> bool Lwt.t) option;
    (** If [Some f], call [f args] before execution. If [true], emit an approval
        request instead of executing. [None] means execute immediately. *)
}

(** Create a server-side tool. If [~needs_approval] is provided, the tool will
    require approval when the predicate returns [true]. *)
val create :
  ?description:string ->
  ?needs_approval:(Yojson.Basic.t -> bool Lwt.t) ->
  parameters:Yojson.Basic.t ->
  execute:(Yojson.Basic.t -> Yojson.Basic.t Lwt.t) ->
  unit ->
  t

(** Create a server-side tool that always requires approval before execution. *)
val create_with_approval :
  ?description:string -> parameters:Yojson.Basic.t -> execute:(Yojson.Basic.t -> Yojson.Basic.t Lwt.t) -> unit -> t

(** Create a client-side tool. The server defines the schema for the LLM but
    does not execute the tool. The frontend provides results via [onToolCall]
    and [addToolOutput]. *)
val create_client_tool : ?description:string -> parameters:Yojson.Basic.t -> unit -> t

(** Parse a JSON string, falling back to [`String s] on parse error. *)
val safe_parse_json_args : string -> Yojson.Basic.t

(** JSON result for denied tool executions.
    Matches upstream's [{type: "execution-denied"}] format. *)
val denied_result : Yojson.Basic.t

(** Execute a tool by name from the tools list.
    Returns an error result if the tool is not found, is client-side only, or throws. *)
val execute_tool :
  tools:(string * t) list ->
  tool_call_id:string ->
  tool_name:string ->
  args:Yojson.Basic.t ->
  Generate_text_result.tool_result Lwt.t

(** Partition tool calls into [(blocked, executable)].
    Blocked = needs approval, client-only (no execute), or unknown tool.
    Executable = has execute and doesn't need approval. *)
val evaluate_approvals :
  tools:(string * t) list ->
  Generate_text_result.tool_call list ->
  (Generate_text_result.tool_call list * Generate_text_result.tool_call list) Lwt.t
