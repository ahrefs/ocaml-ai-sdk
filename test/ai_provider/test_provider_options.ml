open Alcotest

(* Define test GADT keys *)
type _ Ai_provider.Provider_options.key += Test_key : string Ai_provider.Provider_options.key
type _ Ai_provider.Provider_options.key += Other_key : int Ai_provider.Provider_options.key

let test_empty () =
  let opts = Ai_provider.Provider_options.empty in
  (check (option string)) "empty has no value" None (Ai_provider.Provider_options.find Test_key opts)

let test_set_and_find () =
  let opts = Ai_provider.Provider_options.empty |> Ai_provider.Provider_options.set Test_key "hello" in
  (check (option string)) "finds value" (Some "hello") (Ai_provider.Provider_options.find Test_key opts)

let test_different_keys () =
  let opts = Ai_provider.Provider_options.empty |> Ai_provider.Provider_options.set Test_key "hello" in
  (check (option int)) "other key not found" None (Ai_provider.Provider_options.find Other_key opts)

let test_set_replaces () =
  let opts =
    Ai_provider.Provider_options.empty
    |> Ai_provider.Provider_options.set Test_key "first"
    |> Ai_provider.Provider_options.set Test_key "second"
  in
  (check (option string)) "replaced" (Some "second") (Ai_provider.Provider_options.find Test_key opts)

let test_find_exn_raises () =
  let opts = Ai_provider.Provider_options.empty in
  check_raises "raises Not_found" Not_found (fun () ->
    ignore (Ai_provider.Provider_options.find_exn Test_key opts : string))

let test_multiple_keys () =
  let opts =
    Ai_provider.Provider_options.empty
    |> Ai_provider.Provider_options.set Test_key "hello"
    |> Ai_provider.Provider_options.set Other_key 42
  in
  (check (option string)) "string key" (Some "hello") (Ai_provider.Provider_options.find Test_key opts);
  (check (option int)) "int key" (Some 42) (Ai_provider.Provider_options.find Other_key opts)

let () =
  run "Provider_options"
    [
      ( "basics",
        [
          test_case "empty" `Quick test_empty;
          test_case "set_and_find" `Quick test_set_and_find;
          test_case "different_keys" `Quick test_different_keys;
          test_case "set_replaces" `Quick test_set_replaces;
          test_case "find_exn_raises" `Quick test_find_exn_raises;
          test_case "multiple_keys" `Quick test_multiple_keys;
        ] );
    ]
