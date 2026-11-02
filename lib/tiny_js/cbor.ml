type t =
  | Null
  | Bool of bool
  | Int of int
  | Text of string
  | Bytes of string
  | Array of t list
  | Map of (string * t) list

let max_uint = (1 lsl 53) - 1
let default_max_depth = 16

let rec equal a b =
  match a, b with
  | Null, Null -> true
  | Bool x, Bool y -> Bool.equal x y
  | Int x, Int y -> Int.equal x y
  | Text x, Text y -> String.equal x y
  | Bytes x, Bytes y -> String.equal x y
  | Array x, Array y -> List.equal equal x y
  | Map x, Map y -> List.equal (fun (k1, v1) (k2, v2) -> String.equal k1 k2 && equal v1 v2) x y
  | (Null | Bool _ | Int _ | Text _ | Bytes _ | Array _ | Map _), _ -> false

let rec pp fmt = function
  | Null -> Format.pp_print_string fmt "null"
  | Bool b -> Format.pp_print_bool fmt b
  | Int n -> Format.pp_print_int fmt n
  | Text s -> Format.fprintf fmt "%S" s
  | Bytes s -> Format.fprintf fmt "h%S" s
  | Array l ->
    Format.fprintf fmt "[@[%a@]]" (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ") pp) l
  | Map l ->
    let pp_binding fmt (k, v) = Format.fprintf fmt "%S: %a" k pp v in
    Format.fprintf fmt "{@[%a@]}" (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ") pp_binding) l

(* ---------- encoding ---------- *)

let add_head buf ~major n =
  let m = major lsl 5 in
  match n with
  | n when n < 24 -> Buffer.add_uint8 buf (m lor n)
  | n when n < 0x100 ->
    Buffer.add_uint8 buf (m lor 24);
    Buffer.add_uint8 buf n
  | n when n < 0x10000 ->
    Buffer.add_uint8 buf (m lor 25);
    Buffer.add_uint16_be buf n
  | n when n < 0x1_0000_0000 ->
    Buffer.add_uint8 buf (m lor 26);
    Buffer.add_int32_be buf (Int32.of_int n)
  | n ->
    Buffer.add_uint8 buf (m lor 27);
    Buffer.add_int64_be buf (Int64.of_int n)

let add_text buf s =
  if not (String.is_valid_utf_8 s) then invalid_arg "Cbor.encode: text is not valid UTF-8";
  add_head buf ~major:3 (String.length s);
  Buffer.add_string buf s

let rec add_item buf = function
  | Null -> Buffer.add_uint8 buf 0xf6
  | Bool false -> Buffer.add_uint8 buf 0xf4
  | Bool true -> Buffer.add_uint8 buf 0xf5
  | Int n when n < 0 || n > max_uint -> Printf.ksprintf invalid_arg "Cbor.encode: integer %d out of range" n
  | Int n -> add_head buf ~major:0 n
  | Text s -> add_text buf s
  | Bytes s ->
    add_head buf ~major:2 (String.length s);
    Buffer.add_string buf s
  | Array l ->
    add_head buf ~major:4 (List.length l);
    List.iter (add_item buf) l
  | Map l ->
    add_head buf ~major:5 (List.length l);
    List.iter
      (fun (k, v) ->
        add_text buf k;
        add_item buf v)
      l

let encode v =
  let buf = Buffer.create 64 in
  add_item buf v;
  Buffer.contents buf

(* ---------- decoding ---------- *)

exception Fail of string

let fail fmt = Printf.ksprintf (fun s -> raise (Fail s)) fmt

let decode_exn ~max_depth s =
  let len = String.length s in
  let pos = ref 0 in
  let need n = if n > len - !pos then fail "unexpected end of input at offset %d (need %d bytes)" !pos n in
  let byte () =
    need 1;
    let b = Char.code (String.unsafe_get s !pos) in
    incr pos;
    b
  in
  let read_arg info =
    match info with
    | i when i < 24 -> i
    | 24 -> byte ()
    | 25 ->
      need 2;
      let v = String.get_uint16_be s !pos in
      pos := !pos + 2;
      v
    | 26 ->
      need 4;
      let v = Int32.to_int (String.get_int32_be s !pos) land 0xFFFF_FFFF in
      pos := !pos + 4;
      v
    | 27 ->
      need 8;
      let v = String.get_int64_be s !pos in
      pos := !pos + 8;
      if Int64.compare v 0L < 0 || Int64.compare v (Int64.of_int max_uint) > 0 then
        fail "integer or length above 2^53-1 at offset %d" (!pos - 8);
      Int64.to_int v
    | 31 -> fail "indefinite length at offset %d" (!pos - 1)
    | i -> fail "reserved additional information %d at offset %d" i (!pos - 1)
  in
  let take n =
    need n;
    let r = String.sub s !pos n in
    pos := !pos + n;
    r
  in
  let text n =
    let r = take n in
    if not (String.is_valid_utf_8 r) then fail "invalid UTF-8 in text string ending at offset %d" !pos;
    r
  in
  (* [n] items of at least one byte each cannot exceed the remaining input: check before looping. *)
  let repeat n f =
    need n;
    let rec go i acc =
      match i >= n with
      | true -> List.rev acc
      | false ->
        let v = f () in
        go (i + 1) (v :: acc)
    in
    go 0 []
  in
  let rec item depth =
    if depth > max_depth then fail "nesting deeper than %d" max_depth;
    let ib = byte () in
    let major = ib lsr 5
    and info = ib land 31 in
    match major with
    | 0 -> Int (read_arg info)
    | 1 -> fail "negative integers are not supported (offset %d)" (!pos - 1)
    | 2 -> Bytes (take (read_arg info))
    | 3 -> Text (text (read_arg info))
    | 4 ->
      let n = read_arg info in
      Array (repeat n (fun () -> item (depth + 1)))
    | 5 ->
      let n = read_arg info in
      let seen = Hashtbl.create 8 in
      let entry () =
        let kb = byte () in
        let key =
          match kb lsr 5 with
          | 3 -> text (read_arg (kb land 31))
          | _ -> fail "map key is not a text string (offset %d)" (!pos - 1)
        in
        if Hashtbl.mem seen key then fail "duplicate map key %S" key;
        Hashtbl.replace seen key ();
        key, item (depth + 1)
      in
      Map (repeat n entry)
    | 6 -> fail "tags are not supported (offset %d)" (!pos - 1)
    | _ ->
    match info with
    | 20 -> Bool false
    | 21 -> Bool true
    | 22 -> Null
    | i -> fail "unsupported simple value or float %d (offset %d)" i (!pos - 1)
  in
  let v = item 0 in
  if !pos <> len then fail "%d trailing bytes after item" (len - !pos);
  v

let decode ?(max_depth = default_max_depth) s = try Ok (decode_exn ~max_depth s) with Fail msg -> Error msg
