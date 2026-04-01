(** Tool definition for the Core SDK.

    Tools have a description, JSON Schema parameters, and an execute function
    that takes JSON args and returns JSON results. Tools can optionally require
    approval before execution via [needs_approval]. *)

type t = {
  description : string option;
  parameters : Yojson.Basic.t;  (** JSON Schema for tool parameters *)
  execute : Yojson.Basic.t -> Yojson.Basic.t Lwt.t;  (** Execute the tool. Args and result are both JSON. *)
  needs_approval : (Yojson.Basic.t -> bool Lwt.t) option;
    (** If [Some f], call [f args] before execution. If [true], emit an approval
        request instead of executing. [None] means execute immediately. *)
}

(** Create a tool. If [~needs_approval] is provided, the tool will require
    approval when the predicate returns [true]. *)
val create :
  ?description:string ->
  ?needs_approval:(Yojson.Basic.t -> bool Lwt.t) ->
  parameters:Yojson.Basic.t ->
  execute:(Yojson.Basic.t -> Yojson.Basic.t Lwt.t) ->
  unit ->
  t

(** Create a tool that always requires approval before execution. *)
val create_with_approval :
  ?description:string -> parameters:Yojson.Basic.t -> execute:(Yojson.Basic.t -> Yojson.Basic.t Lwt.t) -> unit -> t

(** Parse a JSON string, falling back to [`String s] on parse error. *)
val safe_parse_json_args : string -> Yojson.Basic.t

(** JSON result for denied tool executions.
    Matches upstream's [{type: "execution-denied"}] format. *)
val denied_result : Yojson.Basic.t

(** Execute a tool by name from the tools list.
    Returns a tool result with error info if the tool is not found or throws. *)
val execute_tool :
  tools:(string * t) list ->
  tool_call_id:string ->
  tool_name:string ->
  args:Yojson.Basic.t ->
  Generate_text_result.tool_result Lwt.t

(** Evaluate approval predicates for a list of tool calls.
    Returns [(pending_approval, ready_to_execute)] — tool calls needing approval
    and those that can execute immediately. *)
val evaluate_approvals :
  tools:(string * t) list ->
  Generate_text_result.tool_call list ->
  (Generate_text_result.tool_call list * Generate_text_result.tool_call list) Lwt.t
