(* Define test GADT keys *)
type _ Ai_provider.Provider_options.key += Test_key : string Ai_provider.Provider_options.key
type _ Ai_provider.Provider_options.key += Other_key : int Ai_provider.Provider_options.key

let test_empty () =
  let opts = Ai_provider.Provider_options.empty in
  Alcotest.(check (option string)) "empty has no value" None (Ai_provider.Provider_options.find Test_key opts)

let test_set_and_find () =
  let opts = Ai_provider.Provider_options.empty |> Ai_provider.Provider_options.set Test_key "hello" in
  Alcotest.(check (option string)) "finds value" (Some "hello") (Ai_provider.Provider_options.find Test_key opts)

let test_different_keys () =
  let opts = Ai_provider.Provider_options.empty |> Ai_provider.Provider_options.set Test_key "hello" in
  Alcotest.(check (option int)) "other key not found" None (Ai_provider.Provider_options.find Other_key opts)

let test_set_replaces () =
  let opts =
    Ai_provider.Provider_options.empty
    |> Ai_provider.Provider_options.set Test_key "first"
    |> Ai_provider.Provider_options.set Test_key "second"
  in
  Alcotest.(check (option string)) "replaced" (Some "second") (Ai_provider.Provider_options.find Test_key opts)

let test_find_exn_raises () =
  let opts = Ai_provider.Provider_options.empty in
  Alcotest.check_raises "raises Not_found" Not_found (fun () ->
    ignore (Ai_provider.Provider_options.find_exn Test_key opts : string))

let test_multiple_keys () =
  let opts =
    Ai_provider.Provider_options.empty
    |> Ai_provider.Provider_options.set Test_key "hello"
    |> Ai_provider.Provider_options.set Other_key 42
  in
  Alcotest.(check (option string)) "string key" (Some "hello") (Ai_provider.Provider_options.find Test_key opts);
  Alcotest.(check (option int)) "int key" (Some 42) (Ai_provider.Provider_options.find Other_key opts)

let () =
  Alcotest.run "Provider_options"
    [
      ( "basics",
        [
          Alcotest.test_case "empty" `Quick test_empty;
          Alcotest.test_case "set_and_find" `Quick test_set_and_find;
          Alcotest.test_case "different_keys" `Quick test_different_keys;
          Alcotest.test_case "set_replaces" `Quick test_set_replaces;
          Alcotest.test_case "find_exn_raises" `Quick test_find_exn_raises;
          Alcotest.test_case "multiple_keys" `Quick test_multiple_keys;
        ] );
    ]
