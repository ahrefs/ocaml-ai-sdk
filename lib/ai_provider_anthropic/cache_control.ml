open Melange_json.Primitives

type breakpoint = Ephemeral
type ttl =
  | Ttl_5m
  | Ttl_1h

let ttl_to_string = function
  | Ttl_5m -> "5m"
  | Ttl_1h -> "1h"

let ttl_of_string = function
  | "5m" -> Ttl_5m
  | "1h" -> Ttl_1h
  | other -> raise (Melange_json.Of_json_error (Melange_json.Unexpected_variant ("Unknown cache TTL: " ^ other)))

(* JSON shape we serialize/deserialize: { "type": "ephemeral", "ttl"?: "5m"|"1h" } *)
type breakpoint_json = {
  type_ : string; [@json.key "type"]
  ttl : string option; [@json.option] [@json.drop_default]
}
[@@deriving json]

type t = {
  cache_type : breakpoint;
  ttl : ttl option;
}

let to_json { cache_type; ttl } =
  let type_ =
    match cache_type with
    | Ephemeral -> "ephemeral"
  in
  breakpoint_json_to_json { type_; ttl = Option.map ttl_to_string ttl }

let of_json json =
  let { type_; ttl } = breakpoint_json_of_json json in
  let cache_type =
    match type_ with
    | "ephemeral" -> Ephemeral
    | other ->
      raise (Melange_json.Of_json_error (Melange_json.Unexpected_variant ("Unknown cache breakpoint type: " ^ other)))
  in
  { cache_type; ttl = Option.map ttl_of_string ttl }

let ephemeral = { cache_type = Ephemeral; ttl = None }
let ephemeral_1h = { cache_type = Ephemeral; ttl = Some Ttl_1h }

let to_json_fields = function
  | None -> []
  | Some cc -> [ "cache_control", to_json cc ]
