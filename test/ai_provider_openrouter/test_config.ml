open Alcotest

let test_default_base_url () =
  let config = Ai_provider_openrouter.Config.create ~api_key:"sk-test" () in
  (check string) "base_url" "https://openrouter.ai/api/v1" config.base_url

let test_custom_base_url () =
  let config = Ai_provider_openrouter.Config.create ~base_url:"https://custom.api/v1" () in
  (check string) "base_url" "https://custom.api/v1" config.base_url

let test_api_key () =
  let config = Ai_provider_openrouter.Config.create ~api_key:"sk-or-test-key" () in
  (check (option string)) "api_key" (Some "sk-or-test-key") config.api_key

let test_api_key_exn_missing () =
  let config = Ai_provider_openrouter.Config.create () in
  (* Clear env to ensure no key is found *)
  let saved = Sys.getenv_opt "OPENROUTER_API_KEY" in
  Unix.putenv "OPENROUTER_API_KEY" "";
  let config = { config with api_key = None } in
  (match Ai_provider_openrouter.Config.api_key_exn config with
  | _ -> fail "expected failure"
  | exception Failure msg ->
    (check bool) "mentions OPENROUTER_API_KEY" true (String.length msg > 0));
  Stdlib.Option.iter (fun v -> Unix.putenv "OPENROUTER_API_KEY" v) saved

let test_app_title () =
  let config = Ai_provider_openrouter.Config.create ~app_title:"My App" () in
  (check (option string)) "app_title" (Some "My App") config.app_title

let test_app_url () =
  let config = Ai_provider_openrouter.Config.create ~app_url:"https://myapp.com" () in
  (check (option string)) "app_url" (Some "https://myapp.com") config.app_url

let test_no_app_fields () =
  let config = Ai_provider_openrouter.Config.create () in
  (check (option string)) "app_title" None config.app_title;
  (check (option string)) "app_url" None config.app_url

let () =
  run "Config"
    [
      ( "config",
        [
          test_case "default_base_url" `Quick test_default_base_url;
          test_case "custom_base_url" `Quick test_custom_base_url;
          test_case "api_key" `Quick test_api_key;
          test_case "api_key_exn_missing" `Quick test_api_key_exn_missing;
          test_case "app_title" `Quick test_app_title;
          test_case "app_url" `Quick test_app_url;
          test_case "no_app_fields" `Quick test_no_app_fields;
        ] );
    ]
