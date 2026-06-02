open Alcotest
module Cache_control = Ai_provider_openrouter.Cache_control

let json_string j = Yojson.Basic.to_string j

let test_to_json_ephemeral () =
  let j = Cache_control.to_json Cache_control.ephemeral in
  (check string) "ephemeral json" {|{"type":"ephemeral"}|} (json_string j)

let test_to_json_ephemeral_1h () =
  let j = Cache_control.to_json Cache_control.ephemeral_1h in
  (check string) "ephemeral_1h json" {|{"type":"ephemeral","ttl":"1h"}|} (json_string j)

let test_to_json_ephemeral_5m () =
  let cc = { Cache_control.cache_type = Cache_control.Ephemeral; ttl = Some Cache_control.Ttl_5m } in
  let j = Cache_control.to_json cc in
  (check string) "ephemeral_5m json" {|{"type":"ephemeral","ttl":"5m"}|} (json_string j)

let test_round_trip_ephemeral () =
  let j = Cache_control.to_json Cache_control.ephemeral in
  let cc = Cache_control.of_json j in
  let j' = Cache_control.to_json cc in
  (check string) "round trip ephemeral" (json_string j) (json_string j')

let test_round_trip_ephemeral_1h () =
  let j = Cache_control.to_json Cache_control.ephemeral_1h in
  let cc = Cache_control.of_json j in
  let j' = Cache_control.to_json cc in
  (check string) "round trip ephemeral_1h" (json_string j) (json_string j')

let test_round_trip_ephemeral_5m () =
  let cc = { Cache_control.cache_type = Cache_control.Ephemeral; ttl = Some Cache_control.Ttl_5m } in
  let j = Cache_control.to_json cc in
  let cc' = Cache_control.of_json j in
  let j' = Cache_control.to_json cc' in
  (check string) "round trip ephemeral_5m" (json_string j) (json_string j')

let () =
  run "Cache_control"
    [
      ( "to_json",
        [
          test_case "ephemeral" `Quick test_to_json_ephemeral;
          test_case "ephemeral_1h" `Quick test_to_json_ephemeral_1h;
          test_case "ephemeral_5m" `Quick test_to_json_ephemeral_5m;
        ] );
      ( "round_trip",
        [
          test_case "ephemeral" `Quick test_round_trip_ephemeral;
          test_case "ephemeral_1h" `Quick test_round_trip_ephemeral_1h;
          test_case "ephemeral_5m" `Quick test_round_trip_ephemeral_5m;
        ] );
    ]
