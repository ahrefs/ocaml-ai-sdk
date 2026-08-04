(** Manage Anthropic beta feature headers. *)

(** Return required beta header values for the given features. *)
val required_betas : thinking:Thinking.t option -> has_pdf:bool -> tool_streaming:bool -> string list

(** Merge required betas into the anthropic-beta header, deduplicating. *)
val merge_beta_headers : user_headers:(string * string) list -> required:string list -> (string * string) list
