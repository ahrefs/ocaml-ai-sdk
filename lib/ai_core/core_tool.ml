type t = {
  description : string option;
  parameters : Yojson.Safe.t;
  execute : Yojson.Safe.t -> Yojson.Safe.t Lwt.t;
}

let safe_parse_json_args s = try Yojson.Safe.from_string s with Yojson.Json_error _ -> `String s
