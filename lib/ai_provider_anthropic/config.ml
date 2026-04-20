type fetch_fn = url:string -> headers:(string * string) list -> body:string -> Yojson.Basic.t Lwt.t

type t = {
  api_key : string option;
  base_url : string;
  default_headers : (string * string) list;
  fetch : fetch_fn option;
  timeouts : Ai_provider.Http_timeouts.t;
}

let create ?api_key ?base_url ?(headers = []) ?fetch ?(timeouts = Ai_provider.Http_timeouts.default) () =
  let api_key =
    match api_key with
    | Some _ -> api_key
    | None -> Sys.getenv_opt "ANTHROPIC_API_KEY"
  in
  let base_url =
    match base_url with
    | Some url -> url
    | None -> "https://api.anthropic.com/v1"
  in
  { api_key; base_url; default_headers = headers; fetch; timeouts }

let api_key_exn t =
  match t.api_key with
  | Some key -> key
  | None ->
    failwith
      "Anthropic API key not configured. Set ANTHROPIC_API_KEY environment variable or pass ~api_key to Config.create."
