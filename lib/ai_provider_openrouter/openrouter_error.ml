(* OpenRouter wraps upstream provider errors in an [error] envelope:
     { "error": { "code", "message", "metadata": { "provider_name", "raw", "error_type" } } }
   [raw] is the verbatim upstream error (often itself a JSON string). We surface the most
   specific readable message we can find, prefixed with the upstream provider name and
   suffixed with the OpenRouter error_type when present. *)

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

(** Parse an OpenRouter [error.code], tolerating int, numeric-string, or float
    encodings that different upstreams emit. *)
let code_of_error_json = function
  | `Assoc fields ->
    (match List.assoc_opt "code" fields with
    | Some (`Int n) -> Some n
    | Some (`Float f) -> Some (int_of_float f)
    | Some (`String s) -> int_of_string_opt (String.trim s)
    | _ -> None)
  | _ -> None

(** Human-readable message from an OpenRouter [error] object:
    [\[provider_name\] <most specific upstream message> (error_type)]. *)
let message_of_error_json = function
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
          | Some _ | None -> message)
        | None -> message
      in
      let suffix =
        match List.assoc_opt "error_type" meta_fields with
        | Some (`String t) when String.length t > 0 -> Printf.sprintf " (%s)" t
        | _ -> ""
      in
      prefix ^ body ^ suffix
    | _ -> message)
  | _ -> "Unknown error"

(** Build a Provider_error from an OpenRouter [error] object.

    [status] is the authoritative HTTP transport status when known (the >=400
    error path); pass it so retryability keys off the real gateway status rather
    than the inner provider [code]. When [status] is omitted (200-embedded,
    choice-level, and streaming errors, which carry no transport status), the
    status is derived from [error.code], defaulting to 200. *)
let of_error_json ?status error_json =
  let status =
    match status with
    | Some status -> status
    | None -> Option.value (code_of_error_json error_json) ~default:200
  in
  let body = message_of_error_json error_json in
  Ai_provider.Provider_error.make_api_error ~provider:"openrouter" ~status ~body ()

let of_response ~status ~body =
  let raw_error () = Ai_provider.Provider_error.make_api_error ~provider:"openrouter" ~status ~body () in
  try
    match Yojson.Basic.from_string body with
    | `Assoc fields ->
      (match List.assoc_opt "error" fields with
      | Some error_json -> of_error_json ~status error_json
      | None -> raw_error ())
    | _ -> raw_error ()
  with Yojson.Json_error _ -> raw_error ()
