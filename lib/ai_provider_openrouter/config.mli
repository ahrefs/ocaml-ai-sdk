(** OpenRouter provider configuration. *)

type compatibility =
  | Strict
  | Compatible

(** Custom HTTP function for testing. *)
type fetch_fn = url:string -> headers:(string * string) list -> body:string -> Yojson.Basic.t Lwt.t

type t = {
  api_key : string option;
  base_url : string;
  default_headers : (string * string) list;
  fetch : fetch_fn option;
  app_title : string option;
  app_url : string option;
  compatibility : compatibility;
  api_keys : (string * string) list;
}

(** Create config. [api_key] defaults to [OPENROUTER_API_KEY] env var.
    [base_url] defaults to ["https://openrouter.ai/api/v1"].
    [app_title] sets the [X-Title] header.
    [app_url] sets the [HTTP-Referer] header.
    [compatibility] defaults to [Compatible].
    [api_keys] are BYOK provider API keys sent as [X-Provider-API-Keys] header. *)
val create :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  ?fetch:fetch_fn ->
  ?app_title:string ->
  ?app_url:string ->
  ?compatibility:compatibility ->
  ?api_keys:(string * string) list ->
  unit ->
  t

(** Returns the API key or raises [Failure] if none configured. *)
val api_key_exn : t -> string
