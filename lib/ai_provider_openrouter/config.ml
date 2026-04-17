type compatibility =
  | Strict
  | Compatible

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
  extra_body : (string * Yojson.Basic.t) list;
}

let create ?api_key ?base_url ?(headers = []) ?fetch ?app_title ?app_url ?(compatibility = Compatible) ?(api_keys = [])
  ?(extra_body = []) () =
  let api_key =
    match api_key with
    | Some _ -> api_key
    | None -> Sys.getenv_opt "OPENROUTER_API_KEY"
  in
  let base_url =
    match base_url with
    | Some url -> url
    | None -> "https://openrouter.ai/api/v1"
  in
  { api_key; base_url; default_headers = headers; fetch; app_title; app_url; compatibility; api_keys; extra_body }

let api_key_exn t =
  match t.api_key with
  | Some key -> key
  | None ->
    failwith
      "OpenRouter API key not configured. Set OPENROUTER_API_KEY environment variable or pass ~api_key to \
       Config.create."
