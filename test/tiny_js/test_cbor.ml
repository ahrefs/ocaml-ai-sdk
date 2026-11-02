open Tiny_js

let cbor = Alcotest.testable Cbor.pp Cbor.equal

let unhex s =
  let s = String.concat "" (String.split_on_char ' ' s) in
  String.init (String.length s / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (2 * i) 2)))

let check_decode name hex expected = Alcotest.(check (result cbor string)) name (Ok expected) (Cbor.decode (unhex hex))

let check_rejects name ?max_depth hex =
  match Cbor.decode ?max_depth (unhex hex) with
  | Ok v -> Alcotest.failf "%s: expected rejection, got %s" name (Format.asprintf "%a" Cbor.pp v)
  | Error _ -> ()

(* Payloads of the annotated examples in PROTOCOL.md section 9. *)
let eval_hex = "a3 61 74 64 65 76 61 6c 62 69 64 01 64 63 6f 64 65 63 31 2b 31"
let hello_hex = "a2 61 74 65 68 65 6c 6c 6f 65 70 72 6f 74 6f 01"

let eval_result_hex = "a4 61 74 6b 65 76 61 6c 5f 72 65 73 75 6c 74 62 69 64 01 62 6f 6b f5 65 76 61 6c 75 65 61 32"

let error_result_hex =
  "a4 61 74 6b 65 76 61 6c 5f 72 65 73 75 6c 74 62 69 64 04 62 6f 6b f4 65 65 72 72 6f 72 64 62 6f 6f 6d"

let eval_value = Cbor.Map [ "t", Text "eval"; "id", Int 1; "code", Text "1+1" ]

let test_spec_vectors () =
  Alcotest.(check string) "eval encodes" (unhex eval_hex) (Cbor.encode eval_value);
  check_decode "eval decodes" eval_hex eval_value;
  Alcotest.(check string) "hello encodes" (unhex hello_hex) (Cbor.encode (Map [ "t", Text "hello"; "proto", Int 1 ]));
  Alcotest.(check string)
    "eval_result encodes" (unhex eval_result_hex)
    (Cbor.encode (Map [ "t", Text "eval_result"; "id", Int 1; "ok", Bool true; "value", Text "2" ]));
  Alcotest.(check string)
    "error result encodes" (unhex error_result_hex)
    (Cbor.encode (Map [ "t", Text "eval_result"; "id", Int 4; "ok", Bool false; "error", Text "boom" ]))

let test_round_trip () =
  let values =
    [
      Cbor.Null;
      Bool true;
      Bool false;
      Int 0;
      Int 23;
      Int 24;
      Int 255;
      Int 256;
      Int 65535;
      Int 65536;
      Int 0xFFFF_FFFF;
      Int 0x1_0000_0000;
      Int Cbor.max_uint;
      Text "";
      Text "héllo \u{1F600}";
      Text (String.make 300 'x');
      Bytes "";
      Bytes "\000\255\128";
      Bytes (String.make 70_000 'b');
      Array [];
      Array [ Int 1; Text "a"; Array [ Null ]; Map [ "k", Bytes "v" ] ];
      Map [];
      Map [ "a", Int 1; "b", Map [ "c", Array [ Bool true ] ] ];
    ]
  in
  List.iter (fun v -> Alcotest.(check (result cbor string)) "round trip" (Ok v) (Cbor.decode (Cbor.encode v))) values

let test_shortest_form () =
  Alcotest.(check string) "23" "\x17" (Cbor.encode (Int 23));
  Alcotest.(check string) "24" "\x18\x18" (Cbor.encode (Int 24));
  Alcotest.(check string) "256" "\x19\x01\x00" (Cbor.encode (Int 256));
  Alcotest.(check string) "65536" "\x1a\x00\x01\x00\x00" (Cbor.encode (Int 65536))

let test_rejections () =
  check_rejects "empty" "";
  check_rejects "trailing byte" "01 00";
  check_rejects "truncated uint" "19 01";
  check_rejects "truncated text" "63 61 62";
  check_rejects "negative int" "20";
  check_rejects "tag" "c1 01";
  check_rejects "undefined" "f7";
  check_rejects "simple value 16" "f0";
  check_rejects "half float" "f9 3c 00";
  check_rejects "single float" "fa 3f 80 00 00";
  check_rejects "double float" "fb 3f f0 00 00 00 00 00 00";
  check_rejects "break" "ff";
  check_rejects "indefinite text" "7f 61 61 ff";
  check_rejects "indefinite bytes" "5f 41 00 ff";
  check_rejects "indefinite array" "9f 01 ff";
  check_rejects "indefinite map" "bf 61 61 01 ff";
  check_rejects "reserved info 28" "1c";
  check_rejects "invalid utf-8" "62 c3 28";
  check_rejects "overlong utf-8" "62 c0 80";
  check_rejects "surrogate utf-8" "63 ed a0 80";
  check_rejects "int above 2^53-1" "1b 00 20 00 00 00 00 00 00";
  check_rejects "int above 2^63" "1b ff ff ff ff ff ff ff ff";
  check_rejects "non-text map key" "a1 01 01";
  check_rejects "duplicate map key" "a2 61 61 01 61 61 02";
  check_rejects "map key invalid utf-8" "a1 61 ff 01"

let test_declared_length_checked_first () =
  (* An array claiming 2^32 items must fail on the remaining length, not try to allocate. *)
  check_rejects "huge array" "9a ff ff ff ff";
  check_rejects "huge map" "ba ff ff ff ff";
  check_rejects "huge bytes" "5a ff ff ff ff 00";
  check_rejects "huge text" "7b 00 1f ff ff ff ff ff ff"

let test_depth_limit () =
  let nested n = String.concat "" (List.init n (fun _ -> "81")) ^ "00" in
  (* n nested arrays around a scalar put the scalar at depth n *)
  check_decode "depth 16 ok" (nested 16)
    (List.fold_left (fun acc _ -> Cbor.Array [ acc ]) (Int 0) (List.init 16 Fun.id));
  check_rejects "depth 17 rejected" (nested 17);
  check_rejects "depth 1000 rejected" (nested 1000);
  check_rejects "custom limit" ~max_depth:2 (nested 3);
  Alcotest.(check bool) "custom limit ok" true (Result.is_ok (Cbor.decode ~max_depth:2 (unhex (nested 2))));
  (* deep nesting cannot overflow the stack *)
  Alcotest.(check bool) "very deep" true (Result.is_error (Cbor.decode (String.make 1_000_000 '\x81')))

let test_encode_invalid () =
  let raises name v =
    Alcotest.check_raises name (Invalid_argument "") (fun () ->
      try ignore (Cbor.encode v : string) with Invalid_argument _ -> raise (Invalid_argument ""))
  in
  raises "negative" (Int (-1));
  raises "too large" (Int (Cbor.max_uint + 1));
  raises "bad utf-8 text" (Text "\xff");
  raises "bad utf-8 key" (Map [ "\xff", Null ])

let () =
  Alcotest.run "cbor"
    [
      ( "cbor",
        [
          Alcotest.test_case "spec vectors" `Quick test_spec_vectors;
          Alcotest.test_case "round trip" `Quick test_round_trip;
          Alcotest.test_case "shortest form" `Quick test_shortest_form;
          Alcotest.test_case "rejections" `Quick test_rejections;
          Alcotest.test_case "declared lengths" `Quick test_declared_length_checked_first;
          Alcotest.test_case "depth limit" `Quick test_depth_limit;
          Alcotest.test_case "encode invalid" `Quick test_encode_invalid;
        ] );
    ]
