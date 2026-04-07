(** Reason why model generation finished. *)

type t =
  | Stop
  | Length
  | Tool_calls
  | Content_filter
  | Error
  | Other of string
  | Unknown

(** Serializes to the upstream AI SDK v6 hyphenated format
    (e.g. ["tool-calls"], ["content-filter"], ["other"]).
    Matches the Zod enum in [ui-message-chunks.ts]. *)
val to_string : t -> string

val of_string : string -> t
