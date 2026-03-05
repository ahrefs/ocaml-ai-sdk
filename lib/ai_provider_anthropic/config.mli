(** Anthropic provider configuration. *)

(** Custom HTTP function for testing. *)
type fetch_fn = url:string -> headers:(string * string) list -> body:string -> Yojson.Safe.t Lwt.t

type t = {
  api_key : string option;
  base_url : string;
  default_headers : (string * string) list;
  fetch : fetch_fn option;
}

(** Create config. [api_key] defaults to [ANTHROPIC_API_KEY] env var.
    [base_url] defaults to ["https://api.anthropic.com/v1"]. *)
val create : ?api_key:string -> ?base_url:string -> ?headers:(string * string) list -> ?fetch:fetch_fn -> unit -> t

(** Returns the API key or raises [Failure] if none configured. *)
val api_key_exn : t -> string
