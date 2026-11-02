open Tiny_js

let run = Lwt_main.run
let max_frame_bytes = 1024

let le32 n =
  let b = Bytes.create 4 in
  Bytes.set_int32_le b 0 (Int32.of_int n);
  Bytes.to_string b

(* Feed [raw] to a reader, then EOF. *)
let read_raw ?(max_frame_bytes = max_frame_bytes) raw =
  let ic, oc = Lwt_io.pipe () in
  let%lwt () = Lwt_io.write oc raw in
  let%lwt () = Lwt_io.close oc in
  Frame.read ~max_frame_bytes ic

let check_error name = function
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s: expected an error" name

let test_round_trip () =
  run
    (let ic, oc = Lwt_io.pipe () in
     let%lwt w1 = Frame.write ~max_frame_bytes oc "hello" in
     let%lwt w2 = Frame.write ~max_frame_bytes oc (String.make max_frame_bytes 'x') in
     let%lwt () = Lwt_io.close oc in
     Alcotest.(check bool) "writes ok" true (w1 = Ok () && w2 = Ok ());
     let%lwt r1 = Frame.read ~max_frame_bytes ic in
     let%lwt r2 = Frame.read ~max_frame_bytes ic in
     let%lwt r3 = Frame.read ~max_frame_bytes ic in
     Alcotest.(check (result (option string) string)) "first" (Ok (Some "hello")) r1;
     Alcotest.(check (result (option string) string)) "second" (Ok (Some (String.make max_frame_bytes 'x'))) r2;
     Alcotest.(check (result (option string) string)) "clean eof" (Ok None) r3;
     Lwt.return_unit)

let test_wire_format () =
  run
    (let ic, oc = Lwt_io.pipe () in
     let%lwt _ = Frame.write ~max_frame_bytes oc "abc" in
     let%lwt () = Lwt_io.close oc in
     let%lwt raw = Lwt_io.read ic in
     Alcotest.(check string) "u32le length then payload" "\003\000\000\000abc" raw;
     Lwt.return_unit)

let test_large_frame () =
  run
    (let max_frame_bytes = 1_000_000 in
     let payload = String.init 300_000 (fun i -> Char.chr (i land 0xff)) in
     let ic, oc = Lwt_io.pipe () in
     let%lwt w, r = Lwt.both (Frame.write ~max_frame_bytes oc payload) (Frame.read ~max_frame_bytes ic) in
     Alcotest.(check bool) "write ok" true (w = Ok ());
     Alcotest.(check (result (option string) string)) "read" (Ok (Some payload)) r;
     Lwt.return_unit)

(* A header claiming far more than is sent must fail on EOF without allocating the claimed size. *)
let test_lying_header () =
  run
    (let max_frame_bytes = Frame.max_allowed_frame_bytes in
     let%lwt r = read_raw ~max_frame_bytes (le32 (max_frame_bytes - 1) ^ "short") in
     check_error "truncated payload under a huge declared length" r;
     Lwt.return_unit)

let test_write_limits () =
  run
    (let _, oc = Lwt_io.pipe () in
     let%lwt too_big = Frame.write ~max_frame_bytes oc (String.make (max_frame_bytes + 1) 'x') in
     let%lwt empty = Frame.write ~max_frame_bytes oc "" in
     Alcotest.(check bool)
       "too large" true
       (too_big = Error (Frame.Too_large { size = max_frame_bytes + 1; max = max_frame_bytes }));
     Alcotest.(check bool) "empty" true (empty = Error Frame.Empty);
     Lwt.return_unit)

let test_read_limits () =
  run
    (let%lwt over = read_raw (le32 (max_frame_bytes + 1)) in
     check_error "over the cap" over;
     (* a header claiming 4 GiB - 1 is refused without trying to read a payload *)
     let%lwt huge = read_raw "\xff\xff\xff\xff" in
     check_error "4 GiB" huge;
     let%lwt zero = read_raw (le32 0 ^ "x") in
     check_error "zero length" zero;
     let%lwt short_prefix = read_raw "\001\000" in
     check_error "eof in prefix" short_prefix;
     let%lwt short_payload = read_raw (le32 10 ^ "abc") in
     check_error "eof in payload" short_payload;
     Lwt.return_unit)

let test_cap_is_per_call () =
  run
    (let%lwt r = read_raw ~max_frame_bytes:4 (le32 5 ^ "hello") in
     check_error "cap 4" r;
     let%lwt r = read_raw ~max_frame_bytes:5 (le32 5 ^ "hello") in
     Alcotest.(check (result (option string) string)) "cap 5" (Ok (Some "hello")) r;
     Lwt.return_unit)

let () =
  Alcotest.run "frame"
    [
      ( "frame",
        [
          Alcotest.test_case "round trip" `Quick test_round_trip;
          Alcotest.test_case "wire format" `Quick test_wire_format;
          Alcotest.test_case "large frame" `Quick test_large_frame;
          Alcotest.test_case "lying header" `Quick test_lying_header;
          Alcotest.test_case "write limits" `Quick test_write_limits;
          Alcotest.test_case "read limits" `Quick test_read_limits;
          Alcotest.test_case "cap per call" `Quick test_cap_is_per_call;
        ] );
    ]
