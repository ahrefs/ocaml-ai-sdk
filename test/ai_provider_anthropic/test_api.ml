(* make_request_body tests *)

let test_minimal_body () =
  let body = Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] () in
  let open Yojson.Safe.Util in
  let model = member "model" body |> to_string in
  Alcotest.(check string) "model" "claude-sonnet-4-6" model;
  let max_tokens = member "max_tokens" body |> to_int in
  Alcotest.(check int) "default max_tokens" 4096 max_tokens

let test_body_with_stream () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~stream:true ()
  in
  let open Yojson.Safe.Util in
  let stream = member "stream" body |> to_bool in
  Alcotest.(check bool) "stream" true stream

let test_body_with_temperature () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~temperature:0.7 ()
  in
  let open Yojson.Safe.Util in
  let temp = member "temperature" body |> to_float in
  Alcotest.(check (float 0.01)) "temperature" 0.7 temp

let test_body_with_thinking () =
  let budget = Ai_provider_anthropic.Thinking.budget_exn 2048 in
  let thinking : Ai_provider_anthropic.Thinking.t = { enabled = true; budget_tokens = budget } in
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~thinking ()
  in
  let open Yojson.Safe.Util in
  let thinking_json = member "thinking" body in
  let thinking_type = member "type" thinking_json |> to_string in
  Alcotest.(check string) "type" "enabled" thinking_type;
  let budget_tokens = member "budget_tokens" thinking_json |> to_int in
  Alcotest.(check int) "budget" 2048 budget_tokens

let test_body_omits_none_fields () =
  let body = Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] () in
  let open Yojson.Safe.Util in
  (* temperature should not be present *)
  let temp = member "temperature" body in
  Alcotest.(check bool) "no temperature" true (temp = `Null)

let test_body_with_system () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~system:"Be helpful"
      ()
  in
  let open Yojson.Safe.Util in
  let system = member "system" body |> to_string in
  Alcotest.(check string) "system" "Be helpful" system

(* Beta headers tests *)

let test_required_betas_thinking () =
  let betas = Ai_provider_anthropic.Beta_headers.required_betas ~thinking:true ~has_pdf:false ~tool_streaming:false in
  Alcotest.(check int) "1 beta" 1 (List.length betas)

let test_required_betas_all () =
  let betas = Ai_provider_anthropic.Beta_headers.required_betas ~thinking:true ~has_pdf:true ~tool_streaming:true in
  Alcotest.(check int) "3 betas" 3 (List.length betas)

let test_merge_deduplicates () =
  let headers =
    Ai_provider_anthropic.Beta_headers.merge_beta_headers
      ~user_headers:[ "anthropic-beta", "pdfs-2024-09-25" ]
      ~required:[ "pdfs-2024-09-25"; "interleaved-thinking-2025-05-14" ]
  in
  let beta_header = List.assoc_opt "anthropic-beta" headers in
  match beta_header with
  | Some v ->
    let parts = String.split_on_char ',' v |> List.map String.trim in
    Alcotest.(check int) "2 unique betas" 2 (List.length parts)
  | None -> Alcotest.fail "expected anthropic-beta header"

(* Mock fetch test *)
let test_messages_with_mock_fetch () =
  let mock_response =
    `Assoc
      [
        "id", `String "msg_test";
        "content", `List [ `Assoc [ "type", `String "text"; "text", `String "Hi" ] ];
        "model", `String "claude-sonnet-4-6";
        "stop_reason", `String "end_turn";
        "usage", `Assoc [ "input_tokens", `Int 5; "output_tokens", `Int 2 ];
      ]
  in
  let fetch ~url:_ ~headers:_ ~body:_ = Lwt.return mock_response in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let body = Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] () in
  let result =
    Lwt_main.run (Ai_provider_anthropic.Anthropic_api.messages ~config ~body ~extra_headers:[] ~stream:false)
  in
  match result with
  | `Json json ->
    let open Yojson.Safe.Util in
    let id = member "id" json |> to_string in
    Alcotest.(check string) "id" "msg_test" id
  | `Stream _ -> Alcotest.fail "expected Json"

let () =
  Alcotest.run "Anthropic_api"
    [
      ( "make_request_body",
        [
          Alcotest.test_case "minimal" `Quick test_minimal_body;
          Alcotest.test_case "stream" `Quick test_body_with_stream;
          Alcotest.test_case "temperature" `Quick test_body_with_temperature;
          Alcotest.test_case "thinking" `Quick test_body_with_thinking;
          Alcotest.test_case "omits_none" `Quick test_body_omits_none_fields;
          Alcotest.test_case "system" `Quick test_body_with_system;
        ] );
      ( "beta_headers",
        [
          Alcotest.test_case "thinking" `Quick test_required_betas_thinking;
          Alcotest.test_case "all" `Quick test_required_betas_all;
          Alcotest.test_case "dedup" `Quick test_merge_deduplicates;
        ] );
      "messages", [ Alcotest.test_case "mock_fetch" `Quick test_messages_with_mock_fetch ];
    ]
