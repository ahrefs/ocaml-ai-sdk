type request_info = { body : Yojson.Safe.t }

type response_info = {
  id : string option;
  model : string option;
  headers : (string * string) list;
  body : Yojson.Safe.t;
}

type t = {
  content : Content.t list;
  finish_reason : Finish_reason.t;
  usage : Usage.t;
  warnings : Warning.t list;
  provider_metadata : Provider_options.t;
  request : request_info;
  response : response_info;
}
