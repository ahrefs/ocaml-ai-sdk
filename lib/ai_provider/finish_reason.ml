type t =
  | Stop
  | Length
  | Tool_calls
  | Content_filter
  | Error
  | Other of string
  | Unknown

let to_string = function
  | Stop -> "stop"
  | Length -> "length"
  | Tool_calls -> "tool-calls"
  | Content_filter -> "content-filter"
  | Error -> "error"
  | Other s -> s
  | Unknown -> "unknown"

let to_wire_string = function
  | Stop -> "stop"
  | Length -> "length"
  | Tool_calls -> "tool-calls"
  | Content_filter -> "content-filter"
  | Error -> "error"
  | Other s -> s
  | Unknown -> "other"

let of_string = function
  | "stop" -> Stop
  | "length" -> Length
  | "tool_calls" | "tool-calls" -> Tool_calls
  | "content_filter" | "content-filter" -> Content_filter
  | "error" -> Error
  | "unknown" -> Unknown
  | s -> Other s
