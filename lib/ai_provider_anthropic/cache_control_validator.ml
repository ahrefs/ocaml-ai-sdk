(* Track cache_control breakpoints across a single request and drop the
   5th+ with a warning. Mirrors @ai-sdk/anthropic's CacheControlValidator. *)

let max_breakpoints = 4

type t = {
  mutable count : int;
  mutable warnings : Ai_provider.Warning.t list;
}

let create () = { count = 0; warnings = [] }

let warnings t = List.rev t.warnings

let take t (cc : Cache_control.t option) : Cache_control.t option =
  match cc with
  | None -> None
  | Some _ ->
    t.count <- t.count + 1;
    (match t.count > max_breakpoints with
    | false -> cc
    | true ->
      let w =
        Ai_provider.Warning.Unsupported_feature
          {
            feature = "cacheControl breakpoint limit";
            details =
              Some
                (Printf.sprintf "Maximum %d cache breakpoints exceeded (found %d). This breakpoint will be ignored."
                   max_breakpoints t.count);
          }
      in
      t.warnings <- w :: t.warnings;
      None)
