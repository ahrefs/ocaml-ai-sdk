open Alcotest

let fields_of body =
  match Ai_provider_openai.Openai_api.request_body_to_json body with
  | `Assoc l -> l
  | _ -> []

let test_make_request_body_minimal () =
  let body =
    Ai_provider_openai.Openai_api.make_request_body ~model:"gpt-4o"
      ~messages:[ `Assoc [ "role", `String "user"; "content", `String "hi" ] ]
      ~stream:false ()
  in
  let fields = fields_of body in
  (check bool) "has model" true (List.mem_assoc "model" fields);
  (check bool) "has messages" true (List.mem_assoc "messages" fields);
  (check bool) "no stream" false (List.mem_assoc "stream" fields)

let test_make_request_body_stream () =
  let body = Ai_provider_openai.Openai_api.make_request_body ~model:"gpt-4o" ~messages:[] ~stream:true () in
  let fields = fields_of body in
  (check bool) "has stream" true (List.mem_assoc "stream" fields);
  (check bool) "has stream_options" true (List.mem_assoc "stream_options" fields)

let test_make_request_body_all_params () =
  let body =
    Ai_provider_openai.Openai_api.make_request_body ~model:"gpt-4o" ~messages:[] ~temperature:0.7 ~top_p:0.9
      ~max_tokens:100 ~user:"test-user" ~reasoning_effort:"high" ~stream:false ()
  in
  let fields = fields_of body in
  (check bool) "has temperature" true (List.mem_assoc "temperature" fields);
  (check bool) "has top_p" true (List.mem_assoc "top_p" fields);
  (check bool) "has max_tokens" true (List.mem_assoc "max_tokens" fields);
  (check bool) "has user" true (List.mem_assoc "user" fields);
  (check bool) "has reasoning_effort" true (List.mem_assoc "reasoning_effort" fields)

let test_mock_fetch () =
  let mock_response =
    `Assoc
      [
        ( "choices",
          `List
            [
              `Assoc
                [
                  "index", `Int 0;
                  "message", `Assoc [ "role", `String "assistant"; "content", `String "test" ];
                  "finish_reason", `String "stop";
                ];
            ] );
        "usage", `Assoc [ "prompt_tokens", `Int 5; "completion_tokens", `Int 3 ];
      ]
  in
  let fetch ~url:_ ~headers:_ ~body:_ = Lwt.return mock_response in
  let config = Ai_provider_openai.Config.create ~api_key:"sk-test" ~fetch () in
  let body =
    Ai_provider_openai.Openai_api.make_request_body ~model:"gpt-4o"
      ~messages:[ `Assoc [ "role", `String "user"; "content", `String "hi" ] ]
      ~stream:false ()
  in
  let result =
    Lwt_main.run (Ai_provider_openai.Openai_api.chat_completions ~config ~body ~extra_headers:[] ~stream:false)
  in
  match result with
  | `Json json ->
    let result = Ai_provider_openai.Convert_response.parse_response json in
    (check int) "content" 1 (List.length result.content)
  | `Stream _ -> fail "expected Json"

let test_headers_with_org () =
  let called = ref false in
  let fetch ~url:_ ~headers ~body:_ =
    called := true;
    let has_org = List.exists (fun (k, _) -> String.equal k "openai-organization") headers in
    let has_proj = List.exists (fun (k, _) -> String.equal k "openai-project") headers in
    let has_auth = List.exists (fun (k, _) -> String.equal k "authorization") headers in
    (check bool) "has org" true has_org;
    (check bool) "has project" true has_proj;
    (check bool) "has auth" true has_auth;
    Lwt.return
      (`Assoc [ "choices", `List []; "usage", `Assoc [ "prompt_tokens", `Int 0; "completion_tokens", `Int 0 ] ])
  in
  let config =
    Ai_provider_openai.Config.create ~api_key:"sk-test" ~organization:"org-123" ~project:"proj-456" ~fetch ()
  in
  let body = Ai_provider_openai.Openai_api.make_request_body ~model:"gpt-4o" ~messages:[] ~stream:false () in
  let _ = Lwt_main.run (Ai_provider_openai.Openai_api.chat_completions ~config ~body ~extra_headers:[] ~stream:false) in
  (check bool) "called" true !called

let () =
  run "Openai_api"
    [
      ( "make_request_body",
        [
          test_case "minimal" `Quick test_make_request_body_minimal;
          test_case "stream" `Quick test_make_request_body_stream;
          test_case "all_params" `Quick test_make_request_body_all_params;
        ] );
      ( "chat_completions",
        [ test_case "mock_fetch" `Quick test_mock_fetch; test_case "headers_with_org" `Quick test_headers_with_org ] );
    ]
