let rec extract_raw_message = function
  | `String s ->
    (try
       let parsed = Yojson.Basic.from_string s in
       extract_raw_message parsed
     with Yojson.Json_error _ -> Some s)
  | `Assoc fields ->
    let try_field name =
      match List.assoc_opt name fields with
      | Some (`String s) when String.length s > 0 -> Some s
      | Some (`Assoc _ as nested) -> extract_raw_message nested
      | _ -> None
    in
    List.find_map try_field [ "message"; "error"; "detail"; "details"; "msg" ]
  | _ -> None

let extract_error_message = function
  | `Assoc fields ->
    let message =
      match List.assoc_opt "message" fields with
      | Some (`String m) -> m
      | _ -> "Unknown error"
    in
    (match List.assoc_opt "metadata" fields with
    | Some (`Assoc meta_fields) ->
      let prefix =
        match List.assoc_opt "provider_name" meta_fields with
        | Some (`String name) when String.length name > 0 -> Printf.sprintf "[%s] " name
        | _ -> ""
      in
      let body =
        match List.assoc_opt "raw" meta_fields with
        | Some raw ->
          (match extract_raw_message raw with
          | Some m when not (String.equal m message) -> m
          | _ -> message)
        | None -> message
      in
      prefix ^ body
    | _ -> message)
  | _ -> "Unknown error"

let of_response ~status ~body =
  let message =
    try
      match Yojson.Basic.from_string body with
      | `Assoc fields ->
        (match List.assoc_opt "error" fields with
        | Some error_json -> extract_error_message error_json
        | None -> body)
      | _ -> body
    with Yojson.Json_error _ -> body
  in
  { Ai_provider.Provider_error.provider = "openrouter"; kind = Api_error { status; body = message } }
