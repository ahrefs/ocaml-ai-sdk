type parse_status =
  | Successful
  | Repaired

let try_parse s = try Some (Yojson.Basic.from_string s) with Yojson.Json_error _ -> None

type scanner_state = {
  in_string : bool;
  escaped : bool;
  stack : char list;
}

let initial_state = { in_string = false; escaped = false; stack = [] }

(** Scan one character, updating parser state. *)
let scan_char state ch =
  match state with
  | { in_string = true; escaped = true; _ } -> { state with escaped = false }
  | { in_string = true; _ } ->
    (match ch with
    | '\\' -> { state with escaped = true }
    | '"' -> { state with in_string = false }
    | _ -> state)
  | { in_string = false; _ } ->
  match ch with
  | '"' -> { state with in_string = true }
  | '{' -> { state with stack = '}' :: state.stack }
  | '[' -> { state with stack = ']' :: state.stack }
  | '}' | ']' ->
    (match state.stack with
    | top :: rest when Char.equal top ch -> { state with stack = rest }
    | _ -> state)
  | _ -> state

(** Walk the string and return final scanner state. *)
let scan input =
  let len = String.length input in
  let rec loop i state =
    match i >= len with
    | true -> state
    | false -> loop (i + 1) (scan_char state (String.get input i))
  in
  loop 0 initial_state

(** Trim trailing whitespace from a string. *)
let rstrip s =
  let len = String.length s in
  let rec find_end i =
    match i < 0 with
    | true -> ""
    | false ->
    match String.get s i with
    | ' ' | '\t' | '\n' | '\r' -> find_end (i - 1)
    | _ -> String.sub s 0 (i + 1)
  in
  find_end (len - 1)

(** Remove trailing comma if present (after stripping whitespace). *)
let trim_trailing_comma s =
  let s = rstrip s in
  let len = String.length s in
  match len > 0 && Char.equal (String.get s (len - 1)) ',' with
  | true -> String.sub s 0 (len - 1)
  | false -> s

(** Remove a trailing incomplete key (e.g. ["key":] or [,"key":]) after
    the last complete value. *)
let trim_trailing_incomplete_pair s =
  let s = rstrip s in
  let len = String.length s in
  (* Look for trailing colon *)
  match len > 0 && Char.equal (String.get s (len - 1)) ':' with
  | false -> s
  | true ->
    (* Find the start of the key before the colon *)
    let before_colon = rstrip (String.sub s 0 (len - 1)) in
    let blen = String.length before_colon in
    (match blen > 0 && Char.equal (String.get before_colon (blen - 1)) '"' with
    | false -> s
    | true ->
      (* Walk backwards to find the opening quote of the key *)
      let rec find_open_quote i =
        match i < 0 with
        | true -> s (* no opening quote found, return original *)
        | false ->
        match Char.equal (String.get before_colon i) '"' with
        | true ->
          let prefix = rstrip (String.sub before_colon 0 i) in
          trim_trailing_comma prefix
        | false -> find_open_quote (i - 1)
      in
      find_open_quote (blen - 2))

(** Build the closer string from scanner state. *)
let build_closers state =
  let buf = Buffer.create 8 in
  (match state.in_string with
  | true -> Buffer.add_char buf '"'
  | false -> ());
  List.iter (fun c -> Buffer.add_char buf c) state.stack;
  Buffer.contents buf

(** Attempt to repair truncated JSON. *)
let repair input =
  let state = scan input in
  (* If we're inside a string, close it first *)
  let base =
    match state.in_string with
    | true -> input ^ "\""
    | false -> input
  in
  (* Trim incomplete trailing content before adding bracket closers *)
  let trimmed = trim_trailing_incomplete_pair (trim_trailing_comma base) in
  (* Re-scan after trimming to get correct bracket closers *)
  let new_state = scan trimmed in
  let final_closers = String.concat "" (List.map (String.make 1) new_state.stack) in
  trimmed ^ final_closers

let is_blank s =
  let len = String.length s in
  let rec loop i =
    match i >= len with
    | true -> true
    | false ->
    match String.get s i with
    | ' ' | '\t' | '\n' | '\r' -> loop (i + 1)
    | _ -> false
  in
  loop 0

let parse input =
  match is_blank input with
  | true -> None
  | false ->
  match try_parse input with
  | Some json -> Some (json, Successful)
  | None ->
    let repaired = repair input in
    Option.map (fun json -> json, Repaired) (try_parse repaired)
