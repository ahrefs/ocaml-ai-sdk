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

let equal a b =
  match a, b with
  | Low, Low | Medium, Medium | High, High | Xhigh, Xhigh | Max, Max -> true
  | (Low | Medium | High | Xhigh | Max), (Low | Medium | High | Xhigh | Max) -> false
