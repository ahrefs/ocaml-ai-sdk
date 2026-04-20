type ('complete, 'partial) t = {
  name : string;
  response_format : Ai_provider.Mode.json_schema option;
  parse_complete : string -> ('complete, string) result;
  parse_partial : string -> 'partial option;
}

let partial_json_parse text =
  match Partial_json.parse text with
  | Some (json, _) -> Some json
  | None -> None

let validate_schema ~schema json =
  match Jsonschema.create_validator_from_json ~schema () with
  | Error err -> Error (Format.asprintf "%a" Jsonschema.pp_compile_error err)
  | Ok validator -> Jsonschema.validate validator json |> Result.map_error Jsonschema.Validation_error.to_string

let mode_of_output = function
  | Some o ->
    (match o.response_format with
    | Some schema -> Ai_provider.Mode.Object_json (Some schema)
    | None -> Ai_provider.Mode.Regular)
  | None -> Ai_provider.Mode.Regular

let fallback_tool_args_text steps =
  let pick (step : Generate_text_result.step) =
    List.find_opt
      (fun (tc : Generate_text_result.tool_call) -> String.equal tc.tool_name Ai_provider.Mode.fallback_json_tool_name)
      step.tool_calls
  in
  List.find_map pick steps |> Option.map (fun (tc : Generate_text_result.tool_call) -> Yojson.Basic.to_string tc.args)

let parse_output output steps =
  match output with
  | Some o ->
    (match o.response_format with
    | Some _ ->
      let final_text = Generate_text_result.join_text steps in
      let text =
        match final_text with
        | "" -> Option.value (fallback_tool_args_text steps) ~default:""
        | s -> s
      in
      (match o.parse_complete text with
      | Ok json -> Some json
      | Error _ -> None)
    | None -> None)
  | None -> None

let text =
  {
    name = "text";
    response_format = None;
    parse_complete = (fun s -> Ok s);
    parse_partial =
      (fun s ->
        match String.length s with
        | 0 -> None
        | _ -> Some s);
  }

let object_ ~name ~schema () =
  let response_format = Some { Ai_provider.Mode.name; schema } in
  let parse_complete text =
    try
      let json = Yojson.Basic.from_string text in
      match validate_schema ~schema json with
      | Ok () -> Ok json
      | Error msg -> Error (Printf.sprintf "Schema validation failed: %s" msg)
    with Yojson.Json_error msg -> Error (Printf.sprintf "Invalid JSON: %s" msg)
  in
  { name; response_format; parse_complete; parse_partial = partial_json_parse }

let array ~name ~element_schema () =
  let element_schema_clean =
    match element_schema with
    | `Assoc pairs -> `Assoc (List.filter (fun (k, _) -> not (String.equal k "$schema")) pairs)
    | json -> json
  in
  let schema =
    `Assoc
      [
        "$schema", `String "http://json-schema.org/draft-07/schema#";
        "type", `String "object";
        "properties", `Assoc [ "elements", `Assoc [ "type", `String "array"; "items", element_schema_clean ] ];
        "required", `List [ `String "elements" ];
        "additionalProperties", `Bool false;
      ]
  in
  let response_format = Some { Ai_provider.Mode.name; schema } in
  let extract_elements pairs =
    match List.assoc_opt "elements" pairs with
    | Some (`List elts) -> Some elts
    | _ -> None
  in
  let validate_element elt =
    match validate_schema ~schema:element_schema elt with
    | Ok () -> true
    | Error _ -> false
  in
  let parse_complete text =
    try
      match Yojson.Basic.from_string text with
      | `Assoc pairs ->
        (match extract_elements pairs with
        | Some elts ->
          let invalid = List.find_opt (fun elt -> not (validate_element elt)) elts in
          (match invalid with
          | Some elt -> Error (Printf.sprintf "Element validation failed: %s" (Yojson.Basic.to_string elt))
          | None -> Ok (`List elts))
        | None -> Error "missing or invalid 'elements' array")
      | _ -> Error "expected JSON object with 'elements' array"
    with Yojson.Json_error msg -> Error (Printf.sprintf "Invalid JSON: %s" msg)
  in
  let parse_partial text =
    match Partial_json.parse text with
    | None -> None
    | Some (json, status) ->
    match json with
    | `Assoc pairs ->
      (match extract_elements pairs with
      | None -> None
      | Some elts ->
        let candidates =
          match status with
          | Partial_json.Repaired ->
            (match List.rev elts with
            | _ :: rest -> List.rev rest
            | [] -> [])
          | Partial_json.Successful -> elts
        in
        let valid = List.filter validate_element candidates in
        Some (`List valid))
    | _ -> None
  in
  { name; response_format; parse_complete; parse_partial }

let choice ~name options =
  let schema =
    `Assoc
      [
        "$schema", `String "http://json-schema.org/draft-07/schema#";
        "type", `String "object";
        ( "properties",
          `Assoc
            [ "result", `Assoc [ "type", `String "string"; "enum", `List (List.map (fun s -> `String s) options) ] ] );
        "required", `List [ `String "result" ];
        "additionalProperties", `Bool false;
      ]
  in
  let response_format = Some { Ai_provider.Mode.name; schema } in
  let parse_complete text =
    try
      match Yojson.Basic.from_string text with
      | `Assoc pairs as json ->
        (match validate_schema ~schema json with
        | Ok () ->
          (match List.assoc_opt "result" pairs with
          | Some value -> Ok value
          | None -> Error "missing 'result' field in choice response")
        | Error msg -> Error (Printf.sprintf "Schema validation failed: %s" msg))
      | _ -> Error "expected JSON object with 'result' field"
    with Yojson.Json_error msg -> Error (Printf.sprintf "Invalid JSON: %s" msg)
  in
  let parse_partial text =
    match Partial_json.parse text with
    | None -> None
    | Some (json, status) ->
    match json with
    | `Assoc pairs ->
      (match List.assoc_opt "result" pairs with
      | Some (`String partial_result) ->
        let potential_matches = List.filter (fun opt -> String.starts_with ~prefix:partial_result opt) options in
        (match status with
        | Partial_json.Successful ->
          if List.exists (String.equal partial_result) options then Some (`String partial_result) else None
        | Partial_json.Repaired ->
        match potential_matches with
        | [ single_match ] -> Some (`String single_match)
        | _ -> None)
      | _ -> None)
    | _ -> None
  in
  { name; response_format; parse_complete; parse_partial }

let enum = choice
