type breakpoint = Ephemeral

type t = { cache_type : breakpoint }

let ephemeral = { cache_type = Ephemeral }

let to_yojson_fields = function
  | None -> []
  | Some { cache_type = Ephemeral } -> [ "cache_control", `Assoc [ "type", `String "ephemeral" ] ]
