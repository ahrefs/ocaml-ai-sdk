type t =
  | Low
  | Medium
  | High
  | Xhigh
  | Max

let to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Xhigh -> "xhigh"
  | Max -> "max"
