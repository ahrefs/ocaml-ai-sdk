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

let mode_of_output = function
  | Some o ->
    (match o.response_format with
    | Some schema -> Ai_provider.Mode.Object_json (Some schema)
    | None -> Ai_provider.Mode.Regular)
  | None -> Ai_provider.Mode.Regular

let parse_output output steps =
  match output with
  | Some o ->
    (match o.response_format with
    | Some _ ->
      let final_text = Generate_text_result.join_text steps in
      (match o.parse_complete final_text with
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

let object_ ~name ~schema ?description:_ () =
  let response_format = Some { Ai_provider.Mode.name; schema } in
  let parse_complete text =
    match Yojson.Basic.from_string text with
    | json ->
      (match Json_schema_validator.validate ~schema json with
      | Ok () -> Ok json
      | Error msg -> Error (Printf.sprintf "Schema validation failed: %s" msg))
    | exception Yojson.Json_error msg -> Error (Printf.sprintf "Invalid JSON: %s" msg)
  in
  { name; response_format; parse_complete; parse_partial = partial_json_parse }

let enum ~name options =
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
    match Yojson.Basic.from_string text with
    | `Assoc pairs as json ->
      (match Json_schema_validator.validate ~schema json with
      | Ok () ->
        (match List.assoc_opt "result" pairs with
        | Some value -> Ok value
        | None -> Error "missing 'result' field in enum response")
      | Error msg -> Error (Printf.sprintf "Schema validation failed: %s" msg))
    | _ -> Error "expected JSON object with 'result' field"
    | exception Yojson.Json_error msg -> Error (Printf.sprintf "Invalid JSON: %s" msg)
  in
  { name; response_format; parse_complete; parse_partial = partial_json_parse }
