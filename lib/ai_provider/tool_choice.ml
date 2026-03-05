type t =
  | Auto
  | Required
  | None_
  | Specific of { tool_name : string }
