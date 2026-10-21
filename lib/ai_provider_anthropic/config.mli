(** Anthropic provider configuration. *)

(** Custom HTTP function for testing. It receives the call's abort signal
    and should stop once the signal settles. A call whose signal settles
    before or during [fetch] fails with [Ai_provider.Abort_signal.Aborted],
    even when [fetch] ignores the signal and returns a value. An exception
    from [fetch] passes through unchanged. *)
type fetch_fn =
  abort_signal:Ai_provider.Abort_signal.t option ->
  url:string ->
  headers:(string * string) list ->
  body:string ->
  Yojson.Basic.t Lwt.t

type t = {
  api_key : string option;
  base_url : string;
  default_headers : (string * string) list;
  fetch : fetch_fn option;
  timeouts : Ai_provider.Http_timeouts.t;
}

(** Create config. [api_key] defaults to [ANTHROPIC_API_KEY] env var.
    [base_url] defaults to ["https://api.anthropic.com/v1"]. *)
val create :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  ?fetch:fetch_fn ->
  ?timeouts:Ai_provider.Http_timeouts.t ->
  unit ->
  t

(** Returns the API key or raises [Failure] if none configured. *)
val api_key_exn : t -> string
