(** Strategy for tool selection during generation. *)

type t =
  | Auto
  | Required
  | None_  (** [None] is an OCaml keyword; underscore suffix avoids clash. *)
  | Specific of { tool_name : string }
