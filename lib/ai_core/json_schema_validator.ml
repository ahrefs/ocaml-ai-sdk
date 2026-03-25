let field_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let field_string_opt key obj =
  match field_opt key obj with
  | Some (`String s) -> Some s
  | _ -> None

let err path msg =
  match path with
  | "" -> Error msg
  | _ -> Error (Printf.sprintf "%s: %s" path msg)

let check_type_single typ value =
  match typ with
  | "string" ->
    (match value with
    | `String _ -> true
    | _ -> false)
  | "number" ->
    (match value with
    | `Int _ | `Float _ -> true
    | _ -> false)
  | "integer" ->
    (match value with
    | `Int _ -> true
    | `Float f -> Float.is_integer f
    | _ -> false)
  | "boolean" ->
    (match value with
    | `Bool _ -> true
    | _ -> false)
  | "null" ->
    (match value with
    | `Null -> true
    | _ -> false)
  | "object" ->
    (match value with
    | `Assoc _ -> true
    | _ -> false)
  | "array" ->
    (match value with
    | `List _ -> true
    | _ -> false)
  | _ -> false

let describe_type = function
  | `String _ -> "string"
  | `Int _ -> "integer"
  | `Float _ -> "number"
  | `Bool _ -> "boolean"
  | `Null -> "null"
  | `Assoc _ -> "object"
  | `List _ -> "array"

let validate_type path schema value =
  match field_opt "type" schema with
  | None -> Ok ()
  | Some (`String typ) ->
    if check_type_single typ value then Ok ()
    else err path (Printf.sprintf "expected type %s, got %s" typ (describe_type value))
  | Some (`List types) ->
    let type_strings =
      List.filter_map
        (function
          | `String s -> Some s
          | _ -> None)
        types
    in
    if List.exists (fun typ -> check_type_single typ value) type_strings then Ok ()
    else (
      let expected = String.concat ", " type_strings in
      err path (Printf.sprintf "expected one of types [%s], got %s" expected (describe_type value)))
  | Some _ -> err path "invalid \"type\" in schema"

let validate_enum path schema value =
  match field_opt "enum" schema with
  | None -> Ok ()
  | Some (`List variants) ->
    if List.exists (fun v -> Yojson.Basic.equal v value) variants then Ok ()
    else err path (Printf.sprintf "value not in enum: %s" (Yojson.Basic.to_string value))
  | Some _ -> err path "invalid \"enum\" in schema"

let validate_required path schema value =
  match field_opt "required" schema, value with
  | None, _ -> Ok ()
  | Some (`List required_fields), `Assoc fields ->
    let missing =
      List.filter_map
        (function
          | `String name -> if List.mem_assoc name fields then None else Some name
          | _ -> None)
        required_fields
    in
    (match missing with
    | [] -> Ok ()
    | m -> err path (Printf.sprintf "missing required fields: %s" (String.concat ", " m)))
  | Some _, _ -> Ok ()

let validate_additional_properties path schema value =
  match field_opt "additionalProperties" schema, value with
  | Some (`Bool false), `Assoc fields ->
    let allowed =
      match field_opt "properties" schema with
      | Some (`Assoc props) -> List.map fst props
      | _ -> []
    in
    let extra = List.filter_map (fun (key, _) -> if List.mem key allowed then None else Some key) fields in
    (match extra with
    | [] -> Ok ()
    | e -> err path (Printf.sprintf "additional properties not allowed: %s" (String.concat ", " e)))
  | _ -> Ok ()

let rec validate_at path schema value =
  match schema with
  | `Assoc [] -> Ok ()
  | `Bool true -> Ok ()
  | `Bool false -> err path "schema rejects all values"
  | `Assoc _ ->
    let ( >>= ) = Result.bind in
    validate_type path schema value >>= fun () ->
    validate_enum path schema value >>= fun () ->
    validate_required path schema value >>= fun () ->
    validate_additional_properties path schema value >>= fun () ->
    validate_properties path schema value >>= fun () -> validate_items path schema value
  | _ -> err path "invalid schema"

and validate_properties path schema value =
  match field_opt "properties" schema, value with
  | Some (`Assoc prop_schemas), `Assoc fields ->
    let rec check = function
      | [] -> Ok ()
      | (name, sub_schema) :: rest ->
      match List.assoc_opt name fields with
      | None -> check rest
      | Some field_value ->
        let sub_path =
          match path with
          | "" -> name
          | _ -> Printf.sprintf "%s.%s" path name
        in
        let ( >>= ) = Result.bind in
        validate_at sub_path sub_schema field_value >>= fun () -> check rest
    in
    check prop_schemas
  | _ -> Ok ()

and validate_items path schema value =
  match field_opt "items" schema, value with
  | Some item_schema, `List items ->
    let rec check i = function
      | [] -> Ok ()
      | item :: rest ->
        let item_path = Printf.sprintf "%s[%d]" path i in
        let ( >>= ) = Result.bind in
        validate_at item_path item_schema item >>= fun () -> check (i + 1) rest
    in
    check 0 items
  | _ -> Ok ()

let validate ~schema json = validate_at "" schema json
