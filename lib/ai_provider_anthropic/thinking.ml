type budget_tokens = int

let budget n = if n >= 1024 then Ok n else Error (Printf.sprintf "thinking budget must be >= 1024, got %d" n)

let budget_exn n =
  match budget n with
  | Ok v -> v
  | Error msg -> invalid_arg msg

let to_int n = n

type t = {
  enabled : bool;
  budget_tokens : budget_tokens;
}
