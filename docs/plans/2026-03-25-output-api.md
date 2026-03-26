# Output API (Structured Output) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `Output.text()`, `Output.object_(schema)`, and `Output.enum(options)` to `generate_text` and `stream_text`, enabling structured JSON output with schema validation — matching Vercel AI SDK v6 `Output` API for full frontend interoperability.

**Architecture:** The `Output` module defines a type with functions for response format, complete parsing, and partial parsing. `generate_text` and `stream_text` accept an optional `?output` parameter. When provided, the mode is set to `Object_json` (instead of `Regular`) and the response text is parsed/validated. No new SSE chunk types — structured output rides on existing `text-delta` chunks. JSON Schema validation uses a standalone validator module.

**Tech Stack:** OCaml 4.14, melange-json-native, yojson, lwt, alcotest

**Scope note:** We defer `Output.array` (requires partial JSON parsing and element streaming) and `Output.choice` to a follow-up. This plan covers `Output.text`, `Output.object_`, and the core infrastructure. `Output.enum` is included as it's a simple wrapper (wraps in `{"result": "..."}` envelope).

---

## Overview of Changes

### New files
- `lib/ai_core/output.ml` / `output.mli` — The `Output` module with `text`, `object_`, `enum` constructors
- `lib/ai_core/json_schema_validator.ml` / `json_schema_validator.mli` — JSON Schema Draft-07 validator (subset needed for structured output)
- `lib/ai_core/partial_json.ml` / `partial_json.mli` — Partial JSON parser (repairs incomplete JSON for streaming)
- `test/ai_core/test_output.ml` — Tests for Output module
- `test/ai_core/test_json_schema_validator.ml` — Tests for JSON Schema validator
- `test/ai_core/test_partial_json.ml` — Tests for partial JSON parser

### Modified files
- `lib/ai_core/prompt_builder.ml` / `.mli` — Add `?mode` parameter to `make_call_options`
- `lib/ai_core/generate_text.ml` / `.mli` — Add `?output` parameter, parse/validate output
- `lib/ai_core/generate_text_result.ml` / `.mli` — Add `output` field (polymorphic)
- `lib/ai_core/stream_text.ml` / `.mli` — Add `?output` parameter, partial output stream
- `lib/ai_core/stream_text_result.ml` / `.mli` — Add `partial_output_stream` and `output` promise
- `lib/ai_core/server_handler.ml` / `.mli` — Wire `?output` through `handle_chat`
- `lib/ai_core/ai_core.ml` / `.mli` — Export `Output`, `Json_schema_validator`, `Partial_json`
- `lib/ai_provider_anthropic/anthropic_model.ml` — Handle `Object_json` mode (inject JSON instruction into system prompt, as Anthropic's API does)
- `test/ai_core/dune` — Add new test executables

---

## Task 1: JSON Schema Validator

A subset validator for JSON Schema Draft-07 sufficient for structured output. We don't need the full spec — just what models actually produce and what the AI SDK validates.

### Step 1: Write failing tests

**File:** `test/ai_core/test_json_schema_validator.ml`

```ocaml
open Alcotest

(* Helper to check validation passes *)
let validates schema json =
  let schema = Yojson.Basic.from_string schema in
  let json = Yojson.Basic.from_string json in
  match Ai_core.Json_schema_validator.validate ~schema json with
  | Ok () -> ()
  | Error msg -> fail msg

(* Helper to check validation fails *)
let rejects schema json =
  let schema = Yojson.Basic.from_string schema in
  let json = Yojson.Basic.from_string json in
  match Ai_core.Json_schema_validator.validate ~schema json with
  | Ok () -> fail "expected validation to fail"
  | Error _ -> ()

(* --- type validation --- *)

let test_string_type () =
  validates {|{"type":"string"}|} {|"hello"|};
  rejects {|{"type":"string"}|} {|42|}

let test_number_type () =
  validates {|{"type":"number"}|} {|3.14|};
  validates {|{"type":"integer"}|} {|42|};
  rejects {|{"type":"integer"}|} {|3.14|}

let test_boolean_type () =
  validates {|{"type":"boolean"}|} {|true|};
  rejects {|{"type":"boolean"}|} {|"yes"|}

let test_null_type () =
  validates {|{"type":"null"}|} {|null|};
  rejects {|{"type":"null"}|} {|0|}

let test_array_type () =
  validates {|{"type":"array","items":{"type":"string"}}|} {|["a","b"]|};
  rejects {|{"type":"array","items":{"type":"string"}}|} {|[1,2]|};
  validates {|{"type":"array"}|} {|[1,"a",true]|}

(* --- object validation --- *)

let test_object_properties () =
  let schema = {|{
    "type":"object",
    "properties":{
      "name":{"type":"string"},
      "age":{"type":"integer"}
    },
    "required":["name"]
  }|} in
  validates schema {|{"name":"Alice","age":30}|};
  validates schema {|{"name":"Bob"}|};
  rejects schema {|{"age":30}|}

let test_additional_properties_false () =
  let schema = {|{
    "type":"object",
    "properties":{"name":{"type":"string"}},
    "required":["name"],
    "additionalProperties":false
  }|} in
  validates schema {|{"name":"Alice"}|};
  rejects schema {|{"name":"Alice","extra":true}|}

(* --- enum validation --- *)

let test_enum () =
  validates {|{"type":"string","enum":["red","green","blue"]}|} {|"red"|};
  rejects {|{"type":"string","enum":["red","green","blue"]}|} {|"yellow"|}

(* --- nested objects --- *)

let test_nested_object () =
  let schema = {|{
    "type":"object",
    "properties":{
      "user":{
        "type":"object",
        "properties":{"name":{"type":"string"}},
        "required":["name"]
      }
    },
    "required":["user"]
  }|} in
  validates schema {|{"user":{"name":"Alice"}}|};
  rejects schema {|{"user":{}}|}

(* --- no schema = accept anything --- *)

let test_empty_schema () =
  validates {|{}|} {|"anything"|};
  validates {|{}|} {|42|};
  validates {|{}|} {|{"nested":true}|}

let () =
  run "Json_schema_validator"
    [
      ( "type",
        [
          test_case "string" `Quick test_string_type;
          test_case "number" `Quick test_number_type;
          test_case "boolean" `Quick test_boolean_type;
          test_case "null" `Quick test_null_type;
          test_case "array" `Quick test_array_type;
        ] );
      ( "object",
        [
          test_case "properties and required" `Quick test_object_properties;
          test_case "additionalProperties false" `Quick test_additional_properties_false;
          test_case "nested" `Quick test_nested_object;
        ] );
      ( "enum",
        [
          test_case "enum values" `Quick test_enum;
        ] );
      ( "misc",
        [
          test_case "empty schema" `Quick test_empty_schema;
        ] );
    ]
```

### Step 2: Run tests to verify they fail

```bash
make build test 2>&1 | tail -5
```
Expected: compilation errors (module not found)

### Step 3: Implement JSON Schema validator

**File:** `lib/ai_core/json_schema_validator.mli`

```ocaml
(** JSON Schema Draft-07 subset validator.

    Validates a [Yojson.Basic.t] value against a JSON Schema.
    Supports: type, properties, required, additionalProperties,
    items, enum. Sufficient for structured output validation. *)

(** [validate ~schema json] returns [Ok ()] if [json] conforms to [schema],
    or [Error msg] describing the first validation failure. *)
val validate : schema:Yojson.Basic.t -> Yojson.Basic.t -> (unit, string) result
```

**File:** `lib/ai_core/json_schema_validator.ml`

```ocaml
let member key = function
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> None

let to_string_list = function
  | `List items ->
    List.filter_map
      (function
        | `String s -> Some s
        | _ -> None)
      items
  | _ -> []

let type_name = function
  | `String _ -> "string"
  | `Int _ | `Float _ -> "number"
  | `Bool _ -> "boolean"
  | `Null -> "null"
  | `Assoc _ -> "object"
  | `List _ -> "array"

let rec validate ~schema json =
  match schema with
  | `Assoc _ -> validate_schema schema json
  | `Bool true -> Ok ()
  | `Bool false -> Error "schema rejects all values"
  | _ -> Ok ()

and validate_schema schema json =
  let open Result in
  let* () = validate_type schema json in
  let* () = validate_enum schema json in
  let* () = validate_properties schema json in
  let* () = validate_required schema json in
  let* () = validate_additional_properties schema json in
  let* () = validate_items schema json in
  Ok ()

and validate_type schema json =
  match member "type" schema with
  | None -> Ok ()
  | Some (`String expected_type) -> check_type expected_type json
  | Some (`List types) ->
    let type_strings =
      List.filter_map
        (function
          | `String s -> Some s
          | _ -> None)
        types
    in
    if List.exists (fun t -> Result.is_ok (check_type t json)) type_strings then Ok ()
    else Error (Printf.sprintf "value of type %s does not match any of [%s]" (type_name json) (String.concat ", " type_strings))
  | Some _ -> Ok ()

and check_type expected_type json =
  let actual = type_name json in
  match expected_type, json with
  | "integer", `Int _ -> Ok ()
  | "integer", `Float f when Float.is_integer f -> Ok ()
  | "integer", _ -> Error (Printf.sprintf "expected integer, got %s" actual)
  | "number", (`Int _ | `Float _) -> Ok ()
  | "number", _ -> Error (Printf.sprintf "expected number, got %s" actual)
  | expected, _ when String.equal expected actual -> Ok ()
  | expected, _ -> Error (Printf.sprintf "expected %s, got %s" expected actual)

and validate_enum schema json =
  match member "enum" schema with
  | None -> Ok ()
  | Some (`List allowed) ->
    if List.exists (fun v -> Yojson.Basic.equal v json) allowed then Ok ()
    else Error (Printf.sprintf "value not in enum: %s" (Yojson.Basic.to_string json))
  | Some _ -> Ok ()

and validate_properties schema json =
  match member "properties" schema, json with
  | Some (`Assoc prop_schemas), `Assoc pairs ->
    List.fold_left
      (fun acc (key, prop_schema) ->
        match acc with
        | Error _ -> acc
        | Ok () ->
          (match List.assoc_opt key pairs with
          | Some value ->
            (match validate ~schema:prop_schema value with
            | Ok () -> Ok ()
            | Error msg -> Error (Printf.sprintf "%s: %s" key msg))
          | None -> Ok ()))
      (Ok ())
      prop_schemas
  | _ -> Ok ()

and validate_required schema json =
  match member "required" schema, json with
  | Some required_json, `Assoc pairs ->
    let required = to_string_list required_json in
    List.fold_left
      (fun acc key ->
        match acc with
        | Error _ -> acc
        | Ok () ->
          if List.mem_assoc key pairs then Ok ()
          else Error (Printf.sprintf "missing required field: %s" key))
      (Ok ())
      required
  | _ -> Ok ()

and validate_additional_properties schema json =
  match member "additionalProperties" schema, member "properties" schema, json with
  | Some (`Bool false), Some (`Assoc prop_schemas), `Assoc pairs ->
    let allowed_keys = List.map fst prop_schemas in
    List.fold_left
      (fun acc (key, _) ->
        match acc with
        | Error _ -> acc
        | Ok () ->
          if List.mem key allowed_keys then Ok ()
          else Error (Printf.sprintf "unexpected additional property: %s" key))
      (Ok ())
      pairs
  | _ -> Ok ()

and validate_items schema json =
  match member "items" schema, json with
  | Some item_schema, `List items ->
    List.fold_left
      (fun acc item ->
        match acc with
        | Error _ -> acc
        | Ok () ->
          match validate ~schema:item_schema item with
          | Ok () -> Ok ()
          | Error msg -> Error (Printf.sprintf "array item: %s" msg))
      (Ok ())
      items
  | _ -> Ok ()
```

### Step 4: Register in dune and ai_core, run tests

Add `json_schema_validator` to `ai_core.ml`/`.mli` module list.

Add `test_json_schema_validator` to test dune `names`.

```bash
make clean build test
```
Expected: all tests pass including new validator tests.

### Step 5: Commit

```bash
git add lib/ai_core/json_schema_validator.ml lib/ai_core/json_schema_validator.mli test/ai_core/test_json_schema_validator.ml
git add lib/ai_core/ai_core.ml lib/ai_core/ai_core.mli test/ai_core/dune
git commit -m "feat(ai_core): add JSON Schema Draft-07 subset validator for structured output"
```

---

## Task 2: Partial JSON Parser

Repairs incomplete JSON for streaming partial output. When the model is mid-generation, the JSON may be truncated (unclosed brackets, strings, etc.). This utility attempts repair.

### Step 1: Write failing tests

**File:** `test/ai_core/test_partial_json.ml`

```ocaml
open Alcotest

let parses_to input expected =
  match Ai_core.Partial_json.parse input with
  | Some (json, status) ->
    let actual = Yojson.Basic.to_string json in
    (check string) "json" expected actual;
    ignore (status : Ai_core.Partial_json.parse_status)
  | None -> fail (Printf.sprintf "failed to parse: %s" input)

let fails_to_parse input =
  match Ai_core.Partial_json.parse input with
  | Some _ -> fail (Printf.sprintf "expected parse failure for: %s" input)
  | None -> ()

let test_complete_json () =
  parses_to {|{"name":"Alice","age":30}|} {|{"name":"Alice","age":30}|};
  parses_to {|[1,2,3]|} {|[1,2,3]|};
  parses_to {|"hello"|} {|"hello"|};
  parses_to {|42|} {|42|}

let test_status_successful () =
  match Ai_core.Partial_json.parse {|{"a":1}|} with
  | Some (_, Successful) -> ()
  | Some (_, Repaired) -> fail "expected Successful"
  | None -> fail "expected parse"

let test_truncated_object () =
  parses_to {|{"name":"Alice","ag|} {|{"name":"Alice"}|};
  parses_to {|{"name":"Alice"|} {|{"name":"Alice"}|};
  parses_to {|{"name":"Ali|} {|{"name":"Ali"}|}

let test_truncated_array () =
  parses_to {|[1,2,|} {|[1,2]|};
  parses_to {|[1,2|} {|[1,2]|};
  parses_to {|["hello","wor|} {|["hello","wor"]|}

let test_truncated_nested () =
  parses_to {|{"users":[{"name":"Alice"},{"name":"Bo|} {|{"users":[{"name":"Alice"},{"name":"Bo"}]}|};
  parses_to {|{"users":[{"name":"Alice"|} {|{"users":[{"name":"Alice"}]}|}

let test_status_repaired () =
  match Ai_core.Partial_json.parse {|{"name":"Ali|} with
  | Some (_, Repaired) -> ()
  | Some (_, Successful) -> fail "expected Repaired"
  | None -> fail "expected parse"

let test_empty_input () =
  fails_to_parse "";
  fails_to_parse "   "

let test_garbage () =
  fails_to_parse "not json at all"

let () =
  run "Partial_json"
    [
      ( "complete",
        [
          test_case "complete json" `Quick test_complete_json;
          test_case "status successful" `Quick test_status_successful;
        ] );
      ( "truncated",
        [
          test_case "object" `Quick test_truncated_object;
          test_case "array" `Quick test_truncated_array;
          test_case "nested" `Quick test_truncated_nested;
          test_case "status repaired" `Quick test_status_repaired;
        ] );
      ( "edge",
        [
          test_case "empty" `Quick test_empty_input;
          test_case "garbage" `Quick test_garbage;
        ] );
    ]
```

### Step 2: Run tests to verify they fail

```bash
make build test 2>&1 | tail -5
```

### Step 3: Implement partial JSON parser

**File:** `lib/ai_core/partial_json.mli`

```ocaml
(** Partial JSON parser — repairs truncated JSON for streaming.

    When a model is mid-generation, JSON may be incomplete (unclosed brackets,
    truncated strings). This module attempts to repair and parse such input. *)

type parse_status =
  | Successful  (** Input was valid JSON as-is *)
  | Repaired  (** Input was repaired (truncated content closed) *)

(** [parse input] attempts to parse potentially incomplete JSON.
    Returns [Some (json, status)] on success, [None] if input is empty or
    cannot be repaired. Repair strategy: close unclosed strings, arrays,
    objects; drop trailing incomplete key-value pairs. *)
val parse : string -> (Yojson.Basic.t * parse_status) option
```

**File:** `lib/ai_core/partial_json.ml`

```ocaml
type parse_status =
  | Successful
  | Repaired

let try_parse s =
  try Some (Yojson.Basic.from_string s) with Yojson.Json_error _ -> None

(** Count unclosed brackets/braces, tracking string state *)
let compute_closers s =
  let len = String.length s in
  let stack = Stack.create () in
  let in_string = ref false in
  let escaped = ref false in
  let i = ref 0 in
  while !i < len do
    let c = s.[!i] in
    if !escaped then escaped := false
    else if !in_string then begin
      match c with
      | '\\' -> escaped := true
      | '"' -> in_string := false
      | _ -> ()
    end
    else begin
      match c with
      | '"' -> in_string := true
      | '{' -> Stack.push '}' stack
      | '[' -> Stack.push ']' stack
      | '}' | ']' -> if not (Stack.is_empty stack) then ignore (Stack.pop stack : char)
      | _ -> ()
    end;
    incr i
  done;
  let closers = Buffer.create 8 in
  (* If we're in a string, close it *)
  if !in_string then Buffer.add_char closers '"';
  (* Close all open brackets *)
  Stack.iter (fun c -> Buffer.add_char closers c) stack;
  Buffer.contents closers

(** Try to fix trailing commas and incomplete key-value pairs before closing *)
let trim_trailing_garbage s =
  let len = String.length s in
  if len = 0 then s
  else begin
    (* Find the last "meaningful" position — skip back past whitespace *)
    let pos = ref (len - 1) in
    while !pos >= 0 && (s.[!pos] = ' ' || s.[!pos] = '\n' || s.[!pos] = '\r' || s.[!pos] = '\t') do
      decr pos
    done;
    if !pos < 0 then s
    else begin
      let last = s.[!pos] in
      match last with
      (* Trailing comma — remove it *)
      | ',' -> String.sub s 0 !pos
      (* Trailing colon — we have incomplete key:value, remove key and colon *)
      | ':' ->
        (* Find the start of the key (opening quote before colon) *)
        let p = ref (!pos - 1) in
        (* skip whitespace before colon *)
        while !p >= 0 && (s.[!p] = ' ' || s.[!p] = '\n' || s.[!p] = '\r' || s.[!p] = '\t') do
          decr p
        done;
        (* Should be at closing quote of key *)
        if !p >= 0 && s.[!p] = '"' then begin
          decr p;
          (* Find opening quote *)
          while !p >= 0 && s.[!p] <> '"' do
            decr p
          done;
          if !p >= 0 then begin
            (* Go before the quote, skip whitespace and comma *)
            let p2 = ref (!p - 1) in
            while !p2 >= 0 && (s.[!p2] = ' ' || s.[!p2] = '\n' || s.[!p2] = '\r' || s.[!p2] = '\t') do
              decr p2
            done;
            if !p2 >= 0 && s.[!p2] = ',' then String.sub s 0 !p2
            else String.sub s 0 !p
          end
          else String.sub s 0 !pos
        end
        else String.sub s 0 !pos
      | _ -> s
    end
  end

let parse input =
  let trimmed = String.trim input in
  if String.length trimmed = 0 then None
  else begin
    (* First, try parsing as-is *)
    match try_parse trimmed with
    | Some json -> Some (json, Successful)
    | None ->
      (* Try repair: trim trailing garbage, then close unclosed brackets *)
      let cleaned = trim_trailing_garbage trimmed in
      let closers = compute_closers cleaned in
      let repaired = cleaned ^ closers in
      match try_parse repaired with
      | Some json -> Some (json, Repaired)
      | None ->
        (* More aggressive: try trimming after computing closers on original *)
        let closers2 = compute_closers trimmed in
        let repaired2 = trimmed ^ closers2 in
        match try_parse repaired2 with
        | Some json -> Some (json, Repaired)
        | None -> None
  end
```

### Step 4: Register and run tests

Add `partial_json` to `ai_core.ml`/`.mli`. Add `test_partial_json` to test dune.

```bash
make clean build test
```

### Step 5: Commit

```bash
git add lib/ai_core/partial_json.ml lib/ai_core/partial_json.mli test/ai_core/test_partial_json.ml
git add lib/ai_core/ai_core.ml lib/ai_core/ai_core.mli test/ai_core/dune
git commit -m "feat(ai_core): add partial JSON parser for streaming structured output"
```

---

## Task 3: Output Module

The core `Output` module with `text`, `object_`, and `enum` constructors.

### Step 1: Write failing tests

**File:** `test/ai_core/test_output.ml`

```ocaml
open Alcotest

(* --- Output.text tests --- *)

let test_text_response_format () =
  let output = Ai_core.Output.text in
  match output.response_format with
  | None -> ()
  | Some _ -> fail "text output should have no response_format"

let test_text_parse_complete () =
  let output = Ai_core.Output.text in
  match output.parse_complete "hello world" with
  | Ok s -> (check string) "text" "hello world" s
  | Error msg -> fail msg

let test_text_parse_partial () =
  let output = Ai_core.Output.text in
  match output.parse_partial "hello" with
  | Some s -> (check string) "partial" "hello" s
  | None -> fail "expected partial"

(* --- Output.object_ tests --- *)

let recipe_schema =
  Yojson.Basic.from_string
    {|{
      "type":"object",
      "properties":{
        "name":{"type":"string"},
        "steps":{"type":"array","items":{"type":"string"}}
      },
      "required":["name","steps"]
    }|}

let test_object_response_format () =
  let output = Ai_core.Output.object_ ~name:"recipe" ~schema:recipe_schema () in
  match output.response_format with
  | Some { Ai_provider.Mode.name; schema } ->
    (check string) "name" "recipe" name;
    (check bool) "has schema" true (schema <> `Null)
  | None -> fail "expected response_format"

let test_object_parse_complete_valid () =
  let output = Ai_core.Output.object_ ~name:"recipe" ~schema:recipe_schema () in
  let json_str = {|{"name":"Pasta","steps":["boil","drain"]}|} in
  match output.parse_complete json_str with
  | Ok json ->
    (match json with
    | `Assoc _ -> ()
    | _ -> fail "expected object")
  | Error msg -> fail msg

let test_object_parse_complete_invalid_json () =
  let output = Ai_core.Output.object_ ~name:"recipe" ~schema:recipe_schema () in
  match output.parse_complete "not json" with
  | Ok _ -> fail "expected error"
  | Error _ -> ()

let test_object_parse_complete_schema_mismatch () =
  let output = Ai_core.Output.object_ ~name:"recipe" ~schema:recipe_schema () in
  match output.parse_complete {|{"name":"Pasta"}|} with
  | Ok _ -> fail "expected schema validation error"
  | Error msg ->
    (check bool) "mentions required" true (String.length msg > 0)

let test_object_parse_partial () =
  let output = Ai_core.Output.object_ ~name:"recipe" ~schema:recipe_schema () in
  match output.parse_partial {|{"name":"Past|} with
  | Some json ->
    (match json with
    | `Assoc pairs ->
      (check bool) "has name" true (List.mem_assoc "name" pairs)
    | _ -> fail "expected object")
  | None -> fail "expected partial parse"

let test_object_parse_partial_empty () =
  let output = Ai_core.Output.object_ ~name:"recipe" ~schema:recipe_schema () in
  match output.parse_partial "" with
  | None -> ()
  | Some _ -> fail "expected None for empty"

(* --- Output.enum tests --- *)

let test_enum_response_format () =
  let output = Ai_core.Output.enum ~name:"color" [ "red"; "green"; "blue" ] in
  match output.response_format with
  | Some { name; schema } ->
    (check string) "name" "color" name;
    (check bool) "has schema" true (schema <> `Null)
  | None -> fail "expected response_format"

let test_enum_parse_complete_valid () =
  let output = Ai_core.Output.enum ~name:"color" [ "red"; "green"; "blue" ] in
  (* The model produces {"result":"red"}, enum unwraps it *)
  match output.parse_complete {|{"result":"red"}|} with
  | Ok (`String "red") -> ()
  | Ok json -> fail (Printf.sprintf "unexpected: %s" (Yojson.Basic.to_string json))
  | Error msg -> fail msg

let test_enum_parse_complete_invalid () =
  let output = Ai_core.Output.enum ~name:"color" [ "red"; "green"; "blue" ] in
  match output.parse_complete {|{"result":"yellow"}|} with
  | Ok _ -> fail "expected error"
  | Error _ -> ()

let test_enum_parse_complete_bad_json () =
  let output = Ai_core.Output.enum ~name:"color" [ "red"; "green"; "blue" ] in
  match output.parse_complete {|not json|} with
  | Ok _ -> fail "expected error"
  | Error _ -> ()

let () =
  run "Output"
    [
      ( "text",
        [
          test_case "response_format" `Quick test_text_response_format;
          test_case "parse_complete" `Quick test_text_parse_complete;
          test_case "parse_partial" `Quick test_text_parse_partial;
        ] );
      ( "object_",
        [
          test_case "response_format" `Quick test_object_response_format;
          test_case "valid complete" `Quick test_object_parse_complete_valid;
          test_case "invalid json" `Quick test_object_parse_complete_invalid_json;
          test_case "schema mismatch" `Quick test_object_parse_complete_schema_mismatch;
          test_case "partial" `Quick test_object_parse_partial;
          test_case "partial empty" `Quick test_object_parse_partial_empty;
        ] );
      ( "enum",
        [
          test_case "response_format" `Quick test_enum_response_format;
          test_case "valid" `Quick test_enum_parse_complete_valid;
          test_case "invalid value" `Quick test_enum_parse_complete_invalid;
          test_case "bad json" `Quick test_enum_parse_complete_bad_json;
        ] );
    ]
```

### Step 2: Run tests to verify they fail

### Step 3: Implement Output module

**File:** `lib/ai_core/output.mli`

```ocaml
(** Structured output API for generate_text and stream_text.

    Matches the Vercel AI SDK v6 Output API: [Output.text], [Output.object_],
    [Output.enum]. Controls model response format and adds parsing/validation. *)

(** An output specification parameterized by the parsed output type.
    - ['complete] is the type returned by [parse_complete] (final validated output)
    - ['partial] is the type returned by [parse_partial] (streaming partial output) *)
type ('complete, 'partial) t = {
  name : string;
  response_format : Ai_provider.Mode.json_schema option;
      (** Schema to pass to the provider via [Mode.Object_json].
          [None] means text mode (no JSON instruction). *)
  parse_complete : string -> ('complete, string) result;
      (** Parse and validate the complete model response text.
          Returns [Error msg] if JSON parsing or schema validation fails. *)
  parse_partial : string -> 'partial option;
      (** Parse a potentially incomplete response for streaming.
          Returns [None] if text is empty or unparseable. No schema validation. *)
}

(** Default text output — no structured format, returns raw text. *)
val text : (string, string) t

(** Object output — model produces JSON matching the given schema.
    [name] and [description] are passed to the provider for context.
    Complete output is validated against the schema.
    Partial output uses repair-and-parse (no validation). *)
val object_ :
  name:string ->
  schema:Yojson.Basic.t ->
  ?description:string ->
  unit ->
  (Yojson.Basic.t, Yojson.Basic.t) t

(** Enum output — model picks one of the given string options.
    Wraps in [{"result":"..."}] envelope for the model, unwraps on parse.
    Complete output validates the choice is in the allowed list.
    Partial output returns the partial JSON as-is. *)
val enum :
  name:string ->
  string list ->
  (Yojson.Basic.t, Yojson.Basic.t) t
```

**File:** `lib/ai_core/output.ml`

```ocaml
type ('complete, 'partial) t = {
  name : string;
  response_format : Ai_provider.Mode.json_schema option;
  parse_complete : string -> ('complete, string) result;
  parse_partial : string -> 'partial option;
}

let text =
  {
    name = "text";
    response_format = None;
    parse_complete = (fun s -> Ok s);
    parse_partial = (fun s -> if String.length s = 0 then None else Some s);
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
  let parse_partial text =
    match Partial_json.parse text with
    | Some (json, _) -> Some json
    | None -> None
  in
  { name; response_format; parse_complete; parse_partial }

let enum ~name options =
  let schema =
    `Assoc
      [
        "$schema", `String "http://json-schema.org/draft-07/schema#";
        "type", `String "object";
        ( "properties",
          `Assoc
            [
              ( "result",
                `Assoc
                  [
                    "type", `String "string";
                    "enum", `List (List.map (fun s -> `String s) options);
                  ] );
            ] );
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
        (* Unwrap the envelope *)
        (match List.assoc_opt "result" pairs with
        | Some value -> Ok value
        | None -> Error "missing 'result' field in enum response")
      | Error msg -> Error (Printf.sprintf "Schema validation failed: %s" msg))
    | _ -> Error "expected JSON object with 'result' field"
    | exception Yojson.Json_error msg -> Error (Printf.sprintf "Invalid JSON: %s" msg)
  in
  let parse_partial text =
    match Partial_json.parse text with
    | Some (json, _) -> Some json
    | None -> None
  in
  { name; response_format; parse_complete; parse_partial }
```

### Step 4: Register and run tests

Add `Output` to `ai_core.ml`/`.mli`. Add `test_output` to test dune.

```bash
make clean build test
```

### Step 5: Commit

```bash
git add lib/ai_core/output.ml lib/ai_core/output.mli test/ai_core/test_output.ml
git add lib/ai_core/ai_core.ml lib/ai_core/ai_core.mli test/ai_core/dune
git commit -m "feat(ai_core): add Output module with text, object_, and enum constructors"
```

---

## Task 4: Wire Output into prompt_builder and generate_text

### Step 1: Add `?mode` parameter to `prompt_builder.make_call_options`

**File:** `lib/ai_core/prompt_builder.mli` — add `?mode` parameter:

```ocaml
val make_call_options :
  messages:Ai_provider.Prompt.message list ->
  tools:Ai_provider.Tool.t list ->
  ?tool_choice:Ai_provider.Tool_choice.t ->
  ?mode:Ai_provider.Mode.t ->           (* NEW *)
  ?max_output_tokens:int ->
  ...
```

**File:** `lib/ai_core/prompt_builder.ml` — change `make_call_options`:

```ocaml
let make_call_options ~messages ~tools ?tool_choice ?(mode = Ai_provider.Mode.Regular) ?max_output_tokens ...
  { Ai_provider.Call_options.prompt = messages; mode; ... }
```

### Step 2: Add `?output` to `generate_text` and `output` field to result

**File:** `lib/ai_core/generate_text_result.mli` — add `output` field:

```ocaml
type t = {
  text : string;
  reasoning : string;
  tool_calls : tool_call list;
  tool_results : tool_result list;
  steps : step list;
  finish_reason : Ai_provider.Finish_reason.t;
  usage : Ai_provider.Usage.t;
  response : Ai_provider.Generate_result.response_info;
  warnings : Ai_provider.Warning.t list;
  output : Yojson.Basic.t option;  (* NEW: parsed structured output *)
}
```

**File:** `lib/ai_core/generate_text.mli` — add `?output` parameter:

```ocaml
val generate_text :
  model:Ai_provider.Language_model.t ->
  ?system:string ->
  ?prompt:string ->
  ?messages:Ai_provider.Prompt.message list ->
  ?tools:(string * Core_tool.t) list ->
  ?tool_choice:Ai_provider.Tool_choice.t ->
  ?output:(Yojson.Basic.t, Yojson.Basic.t) Output.t ->  (* NEW *)
  ?max_steps:int ->
  ...
```

**File:** `lib/ai_core/generate_text.ml`:
- Accept `?output` parameter
- Derive `mode` from `output.response_format`
- Pass `~mode` to `make_call_options`
- After final step, if `output` is provided with `response_format`, call `output.parse_complete` on the accumulated text
- Set `result.output` accordingly

The key change in `generate_text.ml`:

```ocaml
let generate_text ~model ?system ?prompt ?messages ?tools ?(tool_choice : Ai_provider.Tool_choice.t option)
  ?output ?(max_steps = 1) ... () =
  ...
  let mode =
    match output with
    | Some o ->
      (match o.response_format with
      | Some schema -> Ai_provider.Mode.Object_json (Some schema)
      | None -> Ai_provider.Mode.Regular)
    | None -> Ai_provider.Mode.Regular
  in
  ...
  (* In make_call_options calls, add ~mode *)
  let opts =
    Prompt_builder.make_call_options ~messages:current_messages ~tools:provider_tools ?tool_choice ~mode ...
  in
  ...
  (* At final return, parse output *)
  let parsed_output =
    match output with
    | Some o ->
      (match o.response_format with
      | Some _ ->
        let final_text = Generate_text_result.join_text all_steps in
        (match o.parse_complete final_text with
        | Ok json -> Some json
        | Error _ -> None)
      | None -> None)
    | None -> None
  in
  Lwt.return { ... output = parsed_output; ... }
```

### Step 3: Write tests for generate_text with output

Add to existing `test/ai_core/test_generate_text.ml`:

```ocaml
(* Mock model that returns JSON *)
let make_json_model json_str =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-json"
    let generate _opts =
      Lwt.return
        { Ai_provider.Generate_result.content = [ Text { text = json_str } ];
          finish_reason = Stop; usage = { input_tokens = 10; output_tokens = 20; total_tokens = Some 30 };
          warnings = []; provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = Some "r1"; model = Some "mock-json"; headers = []; body = `Null } }
    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let test_generate_with_object_output () =
  let schema = Yojson.Basic.from_string {|{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}|} in
  let output = Ai_core.Output.object_ ~name:"test" ~schema () in
  let model = make_json_model {|{"name":"Alice"}|} in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ~output () ) in
  match result.output with
  | Some (`Assoc [("name", `String "Alice")]) -> ()
  | Some json -> fail (Printf.sprintf "unexpected output: %s" (Yojson.Basic.to_string json))
  | None -> fail "expected output"

let test_generate_with_enum_output () =
  let output = Ai_core.Output.enum ~name:"sentiment" ["positive"; "negative"; "neutral"] in
  let model = make_json_model {|{"result":"positive"}|} in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ~output ()) in
  match result.output with
  | Some (`String "positive") -> ()
  | Some json -> fail (Printf.sprintf "unexpected output: %s" (Yojson.Basic.to_string json))
  | None -> fail "expected output"

let test_generate_with_invalid_output () =
  let schema = Yojson.Basic.from_string {|{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}|} in
  let output = Ai_core.Output.object_ ~name:"test" ~schema () in
  let model = make_json_model {|not valid json|} in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ~output ()) in
  match result.output with
  | None -> ()
  | Some _ -> fail "expected None for invalid json"

let test_generate_without_output () =
  let model = make_text_model "Hello!" in
  let result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"test" ()) in
  match result.output with
  | None -> ()
  | Some _ -> fail "expected None when no output spec"
```

Add these to the test suite list in the same file.

### Step 4: Run tests

```bash
make clean build test
```

### Step 5: Commit

```bash
git add lib/ai_core/prompt_builder.ml lib/ai_core/prompt_builder.mli
git add lib/ai_core/generate_text.ml lib/ai_core/generate_text.mli
git add lib/ai_core/generate_text_result.ml lib/ai_core/generate_text_result.mli
git add test/ai_core/test_generate_text.ml
git commit -m "feat(ai_core): wire Output into generate_text with schema validation"
```

---

## Task 5: Wire Output into stream_text

### Step 1: Add `partial_output_stream` and `output` to `Stream_text_result`

**File:** `lib/ai_core/stream_text_result.mli` — add fields:

```ocaml
type t = {
  text_stream : string Lwt_stream.t;
  full_stream : Text_stream_part.t Lwt_stream.t;
  partial_output_stream : Yojson.Basic.t Lwt_stream.t;  (* NEW *)
  usage : Ai_provider.Usage.t Lwt.t;
  finish_reason : Ai_provider.Finish_reason.t Lwt.t;
  steps : Generate_text_result.step list Lwt.t;
  warnings : Ai_provider.Warning.t list;
  output : Yojson.Basic.t option Lwt.t;  (* NEW: resolves to parsed complete output *)
}
```

**File:** `lib/ai_core/stream_text_result.ml` — update record type.

### Step 2: Add `?output` to `stream_text`

**File:** `lib/ai_core/stream_text.mli` — add `?output` parameter (same position as generate_text).

**File:** `lib/ai_core/stream_text.ml`:
- Accept `?output` parameter
- Derive `mode` from `output.response_format`, pass to `make_call_options`
- Create `partial_output_stream` and `output` promise
- In the background loop, after each text delta, if output has `response_format`, accumulate text and call `parse_partial` on the accumulated text — push to `partial_output_stream` only when the stringified JSON changes (dedup)
- On final step, call `parse_complete` and resolve `output` promise

The key changes:

```ocaml
(* Create partial output stream *)
let partial_output_stream, partial_output_push = Lwt_stream.create () in
let output_promise, output_resolver = Lwt.wait () in
let last_partial_json = ref "" in  (* for dedup *)

(* After accumulating text in text_buf, if we have structured output: *)
let maybe_emit_partial () =
  match output with
  | Some o when Option.is_some o.response_format ->
    let accumulated = Buffer.contents text_buf in
    (match o.parse_partial accumulated with
    | Some json ->
      let json_str = Yojson.Basic.to_string json in
      if not (String.equal json_str !last_partial_json) then begin
        last_partial_json := json_str;
        partial_output_push (Some json)
      end
    | None -> ())
  | _ -> ()
in

(* Call maybe_emit_partial after each Text delta in consume_provider_stream *)

(* On final step completion: *)
let parsed_output =
  match output with
  | Some o when Option.is_some o.response_format ->
    let final_text = ... in
    (match o.parse_complete final_text with
    | Ok json -> Some json
    | Error _ -> None)
  | _ -> None
in
partial_output_push None;
Lwt.wakeup_later output_resolver parsed_output;
```

### Step 3: Write tests

Add to `test/ai_core/test_stream_text.ml`:

```ocaml
(* Mock streaming model that returns JSON in chunks *)
let make_json_stream_model chunks =
  (* ... creates a model that streams the given text chunks *)

let test_stream_with_object_output () =
  let schema = Yojson.Basic.from_string {|{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}|} in
  let output = Ai_core.Output.object_ ~name:"test" ~schema () in
  (* model streams: {"name" then :"Alice"} *)
  let model = make_json_stream_model ["{\"name\""; ":\"Alice\"}"] in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"test" ~output () in
  (* Collect partial outputs *)
  let partials = Lwt_main.run (Lwt_stream.to_list result.partial_output_stream) in
  (check bool) "has partials" true (List.length partials > 0);
  (* Check final output *)
  let final = Lwt_main.run result.output in
  match final with
  | Some (`Assoc [("name", `String "Alice")]) -> ()
  | _ -> fail "expected final output"

let test_stream_without_output () =
  let model = make_text_stream_model ["Hello", " world"] in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"test" () in
  let partials = Lwt_main.run (Lwt_stream.to_list result.partial_output_stream) in
  (check int) "no partials" 0 (List.length partials);
  let final = Lwt_main.run result.output in
  match final with
  | None -> ()
  | Some _ -> fail "expected None"
```

### Step 4: Update `to_ui_message_stream` / `to_ui_message_sse_stream`

These functions access `t.full_stream`, `t.text_stream` etc. They don't need to change since structured output rides on existing text-delta chunks. The new fields are orthogonal.

### Step 5: Run tests

```bash
make clean build test
```

### Step 6: Commit

```bash
git add lib/ai_core/stream_text.ml lib/ai_core/stream_text.mli
git add lib/ai_core/stream_text_result.ml lib/ai_core/stream_text_result.mli
git add test/ai_core/test_stream_text.ml
git commit -m "feat(ai_core): wire Output into stream_text with partial output streaming"
```

---

## Task 6: Anthropic Provider — Handle Object_json Mode

The Anthropic provider currently ignores `opts.mode`. When `Object_json` is set, we need to instruct the model to produce JSON. Anthropic doesn't have a native `response_format` API parameter — instead, the convention is to add a JSON instruction to the system prompt and/or use tool-based extraction.

For simplicity and reliability, we follow the approach used by the TypeScript AI SDK's Anthropic provider: **prepend a JSON instruction to the system prompt** when `mode = Object_json`.

### Step 1: Write tests

Add to `test/ai_provider_anthropic/` — test that `prepare_request` includes JSON instruction when mode is `Object_json`.

This requires reading the test structure for the Anthropic provider first. The key test: verify that when `call_options.mode = Object_json (Some schema)`, the request body includes a system prompt instructing JSON output.

### Step 2: Modify `anthropic_model.ml`

In `prepare_request`, after extracting system prompt, check `opts.mode`:

```ocaml
let system =
  match opts.mode with
  | Object_json (Some { name; schema }) ->
    let json_instruction =
      Printf.sprintf
        "Respond ONLY with a JSON object matching this schema (name: %s):\n%s\n\nDo not include any other text, markdown formatting, or code blocks. Output raw JSON only."
        name (Yojson.Basic.pretty_to_string schema)
    in
    (match system with
    | Some s -> Some (s ^ "\n\n" ^ json_instruction)
    | None -> Some json_instruction)
  | Object_json None ->
    let json_instruction =
      "Respond ONLY with valid JSON. Do not include any other text, markdown formatting, or code blocks. Output raw JSON only."
    in
    (match system with
    | Some s -> Some (s ^ "\n\n" ^ json_instruction)
    | None -> Some json_instruction)
  | Regular | Object_tool _ -> system
in
```

### Step 3: Run tests

```bash
make clean build test
```

### Step 4: Commit

```bash
git add lib/ai_provider_anthropic/anthropic_model.ml
git add test/ai_provider_anthropic/...
git commit -m "feat(anthropic): handle Object_json mode by injecting JSON instruction into system prompt"
```

---

## Task 7: Wire Output into server_handler

### Step 1: Add `?output` parameter to `handle_chat`

**File:** `lib/ai_core/server_handler.mli`:

```ocaml
val handle_chat :
  model:Ai_provider.Language_model.t ->
  ?tools:(string * Core_tool.t) list ->
  ?max_steps:int ->
  ?system:string ->
  ?output:(Yojson.Basic.t, Yojson.Basic.t) Output.t ->  (* NEW *)
  ?send_reasoning:bool ->
  ?cors:bool ->
  ?provider_options:Ai_provider.Provider_options.t ->
  ...
```

**File:** `lib/ai_core/server_handler.ml` — pass `?output` through to `stream_text`:

```ocaml
let result = Stream_text.stream_text ~model ~messages ?tools ?max_steps ?output ?provider_options () in
```

### Step 2: Run tests

```bash
make clean build test
```

### Step 3: Commit

```bash
git add lib/ai_core/server_handler.ml lib/ai_core/server_handler.mli
git commit -m "feat(ai_core): wire Output through server_handler handle_chat"
```

---

## Task 8: Final integration — format, test, review

### Step 1: Run full test suite

```bash
make clean build test fmt
```

Fix any compilation errors, formatting issues, or test failures.

### Step 2: Verify all 228+ tests pass

```bash
make test 2>&1 | grep -E "(PASS|FAIL|tests)"
```

### Step 3: Commit any fixes

```bash
git commit -m "chore: fix formatting and test issues from Output API integration"
```

---

## Future v2 Enhancements

### Deriver-based schema construction for user-facing schemas

Currently, users must hand-write `Yojson.Basic.t` schema values to pass to `Output.object_`
and `Output.array`. This is error-prone and verbose. A deriver-based approach (e.g. a
`ppx_deriving_jsonschema` or integration with an existing schema-generation library) would
allow users to derive JSON schemas directly from OCaml record types:

```ocaml
type recipe = {
  name : string;
  steps : string list;
} [@@deriving jsonschema]

let output = Output.object_ ~name:"recipe" ~schema:recipe_jsonschema ()
```

### Typed Output.t — better DX for getting typed responses instead of Yojson.Basic.t

The `Output.t` type is already parameterized (`('complete, 'partial) t`), so the
infrastructure supports typed returns. The convenience constructors (`object_`, `array`,
`choice`) currently return `Yojson.Basic.t` as the complete type. We should add an
optional `?parse` argument directly to `object_` and `array` so users get typed
responses without a separate combinator:

```ocaml
val object_ :
  name:string ->
  schema:Yojson.Basic.t ->
  ?parse:(Yojson.Basic.t -> ('a, string) result) ->
  unit ->
  ('a, Yojson.Basic.t) t

(* Usage with melange-json-native / ppx_deriving_yojson *)
let recipe_output =
  Output.object_ ~name:"recipe" ~schema:recipe_jsonschema
    ~parse:(fun json -> recipe_of_json json)
    ()
```

When `~parse` is omitted, the function returns `Yojson.Basic.t` as today. When
provided, the validated JSON is transformed into the user's type and the `'complete`
type parameter flows through naturally.

For a fully integrated experience, combine with deriver-based schema construction:

```ocaml
type recipe = {
  name : string;
  steps : string list;
} [@@deriving jsonschema, of_json]

let recipe_output =
  Output.object_ ~name:"recipe" ~schema:recipe_jsonschema
    ~parse:recipe_of_json ()
```
