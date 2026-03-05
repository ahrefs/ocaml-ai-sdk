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
  | Tool_calls -> "tool_calls"
  | Content_filter -> "content_filter"
  | Error -> "error"
  | Other s -> s
  | Unknown -> "unknown"

let of_string = function
  | "stop" -> Stop
  | "length" -> Length
  | "tool_calls" -> Tool_calls
  | "content_filter" -> Content_filter
  | "error" -> Error
  | "unknown" -> Unknown
  | s -> Other s
