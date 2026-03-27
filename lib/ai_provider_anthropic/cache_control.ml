open Melange_json.Primitives

type breakpoint = Ephemeral

type breakpoint_json = { type_ : string [@json.key "type"] } [@@deriving json]

let breakpoint_to_json = function
  | Ephemeral -> breakpoint_json_to_json { type_ = "ephemeral" }

let breakpoint_of_json json =
  let { type_ } = breakpoint_json_of_json json in
  match type_ with
  | "ephemeral" -> Ephemeral
  | other ->
    raise (Melange_json.Of_json_error (Melange_json.Unexpected_variant ("Unknown cache breakpoint type: " ^ other)))

type t = { cache_type : breakpoint } [@@deriving json]

let ephemeral = { cache_type = Ephemeral }

let to_json_fields = function
  | None -> []
  | Some { cache_type } -> [ "cache_control", breakpoint_to_json cache_type ]
