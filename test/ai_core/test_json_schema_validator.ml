open Alcotest

let validate = Ai_core.Json_schema_validator.validate

let validates msg ~schema json = (check (result unit string)) msg (Ok ()) (validate ~schema json)

let rejects msg ~schema json =
  match validate ~schema json with
  | Error _ -> ()
  | Ok () -> fail (Printf.sprintf "%s: expected validation to fail" msg)

(* Type validation *)

let test_type_string () =
  let schema = `Assoc [ "type", `String "string" ] in
  validates "string matches" ~schema (`String "hello");
  rejects "int rejected" ~schema (`Int 42)

let test_type_number () =
  let schema = `Assoc [ "type", `String "number" ] in
  validates "int is number" ~schema (`Int 42);
  validates "float is number" ~schema (`Float 3.14);
  rejects "string rejected" ~schema (`String "hi")

let test_type_integer () =
  let schema = `Assoc [ "type", `String "integer" ] in
  validates "int matches" ~schema (`Int 7);
  validates "whole float matches" ~schema (`Float 5.0);
  rejects "fractional float rejected" ~schema (`Float 3.14)

let test_type_boolean () =
  let schema = `Assoc [ "type", `String "boolean" ] in
  validates "bool matches" ~schema (`Bool true);
  rejects "string rejected" ~schema (`String "true")

let test_type_null () =
  let schema = `Assoc [ "type", `String "null" ] in
  validates "null matches" ~schema `Null;
  rejects "string rejected" ~schema (`String "null")

let test_type_array () =
  let schema = `Assoc [ "type", `String "array" ] in
  validates "list matches" ~schema (`List [ `Int 1; `Int 2 ]);
  rejects "object rejected" ~schema (`Assoc [])

let test_type_list () =
  let schema = `Assoc [ "type", `List [ `String "string"; `String "null" ] ] in
  validates "string matches anyOf" ~schema (`String "hi");
  validates "null matches anyOf" ~schema `Null;
  rejects "int rejected" ~schema (`Int 1)

(* Object validation *)

let test_object_properties () =
  let schema =
    `Assoc
      [
        "type", `String "object";
        ( "properties",
          `Assoc [ "name", `Assoc [ "type", `String "string" ]; "age", `Assoc [ "type", `String "integer" ] ] );
        "required", `List [ `String "name" ];
      ]
  in
  validates "valid object" ~schema (`Assoc [ "name", `String "Alice"; "age", `Int 30 ]);
  validates "optional field missing" ~schema (`Assoc [ "name", `String "Bob" ]);
  rejects "required field missing" ~schema (`Assoc [ "age", `Int 25 ]);
  rejects "wrong property type" ~schema (`Assoc [ "name", `Int 123; "age", `Int 25 ])

let test_additional_properties_false () =
  let schema =
    `Assoc
      [
        "type", `String "object";
        "properties", `Assoc [ "x", `Assoc [ "type", `String "integer" ] ];
        "additionalProperties", `Bool false;
      ]
  in
  validates "only declared props" ~schema (`Assoc [ "x", `Int 1 ]);
  rejects "extra prop rejected" ~schema (`Assoc [ "x", `Int 1; "y", `Int 2 ])

(* Enum validation *)

let test_enum () =
  let schema = `Assoc [ "enum", `List [ `String "a"; `String "b"; `Int 1 ] ] in
  validates "string in enum" ~schema (`String "a");
  validates "int in enum" ~schema (`Int 1);
  rejects "value not in enum" ~schema (`String "c")

(* Items validation *)

let test_items () =
  let schema = `Assoc [ "type", `String "array"; "items", `Assoc [ "type", `String "string" ] ] in
  validates "all strings" ~schema (`List [ `String "a"; `String "b" ]);
  validates "empty array" ~schema (`List []);
  rejects "non-string item" ~schema (`List [ `String "a"; `Int 1 ])

(* Nested objects *)

let test_nested () =
  let schema =
    `Assoc
      [
        "type", `String "object";
        ( "properties",
          `Assoc
            [
              ( "address",
                `Assoc
                  [
                    "type", `String "object";
                    "properties", `Assoc [ "city", `Assoc [ "type", `String "string" ] ];
                    "required", `List [ `String "city" ];
                  ] );
            ] );
        "required", `List [ `String "address" ];
      ]
  in
  validates "valid nested" ~schema (`Assoc [ "address", `Assoc [ "city", `String "NYC" ] ]);
  rejects "missing nested required" ~schema (`Assoc [ "address", `Assoc [] ])

(* Empty schema *)

let test_empty_schema () =
  let schema = `Assoc [] in
  validates "string accepted" ~schema (`String "anything");
  validates "int accepted" ~schema (`Int 42);
  validates "null accepted" ~schema `Null;
  validates "object accepted" ~schema (`Assoc [ "x", `Int 1 ])

(* Error messages *)

let test_type_mismatch_error () =
  let schema = `Assoc [ "type", `String "string" ] in
  (check (result unit string)) "error message" (Error "expected type string, got integer") (validate ~schema (`Int 42))

let test_missing_required_error () =
  let schema =
    `Assoc
      [
        "type", `String "object";
        "properties", `Assoc [ "a", `Assoc []; "b", `Assoc [] ];
        "required", `List [ `String "a"; `String "b" ];
      ]
  in
  (check (result unit string)) "error message" (Error "missing required fields: a, b") (validate ~schema (`Assoc []))

let () =
  run "Json_schema_validator"
    [
      ( "type",
        [
          test_case "string" `Quick test_type_string;
          test_case "number" `Quick test_type_number;
          test_case "integer" `Quick test_type_integer;
          test_case "boolean" `Quick test_type_boolean;
          test_case "null" `Quick test_type_null;
          test_case "array" `Quick test_type_array;
          test_case "type list (anyOf)" `Quick test_type_list;
        ] );
      ( "object",
        [
          test_case "properties + required" `Quick test_object_properties;
          test_case "additionalProperties false" `Quick test_additional_properties_false;
        ] );
      "enum", [ test_case "enum values" `Quick test_enum ];
      "items", [ test_case "array items" `Quick test_items ];
      "nested", [ test_case "nested objects" `Quick test_nested ];
      "empty_schema", [ test_case "accepts anything" `Quick test_empty_schema ];
      ( "errors",
        [
          test_case "type mismatch" `Quick test_type_mismatch_error;
          test_case "missing required" `Quick test_missing_required_error;
        ] );
    ]
