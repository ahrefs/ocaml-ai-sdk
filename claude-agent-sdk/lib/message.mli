(** Typed message variant dispatched from raw CLI JSON. *)

type t =
  | System of Types.system_message
  | Assistant of Types.assistant_message
  | Result of Types.result_message
  | User of Types.user_message
  | Control_request of Types.control_request
  | Control_response of Types.control_response
  | Unknown of Yojson.Safe.t

(** Parse raw JSON into a typed message. Returns [Unknown] for
    unrecognized message types. *)
val of_json : Yojson.Safe.t -> t

val is_result : t -> bool
val result_text : t -> string option
val assistant_text : t -> string option
val session_id : t -> string option
