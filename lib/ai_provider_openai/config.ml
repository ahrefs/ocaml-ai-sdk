type fetch_fn = url:string -> headers:(string * string) list -> body:string -> Yojson.Basic.t Lwt.t

type t = {
  api_key : string option;
  base_url : string;
  default_headers : (string * string) list;
  fetch : fetch_fn option;
  organization : string option;
  project : string option;
  timeouts : Ai_provider.Http_timeouts.t;
}

let create ?api_key ?base_url ?(headers = []) ?fetch ?organization ?project
  ?(timeouts = Ai_provider.Http_timeouts.default) () =
  let api_key =
    match api_key with
    | Some _ -> api_key
    | None -> Sys.getenv_opt "OPENAI_API_KEY"
  in
  let base_url =
    match base_url with
    | Some url -> url
    | None -> "https://api.openai.com/v1"
  in
  { api_key; base_url; default_headers = headers; fetch; organization; project; timeouts }

let api_key_exn t =
  match t.api_key with
  | Some key -> key
  | None ->
    failwith "OpenAI API key not configured. Set OPENAI_API_KEY environment variable or pass ~api_key to Config.create."
