(* make_request_body tests *)

open Melange_json.Primitives
open Alcotest

type thinking_json = {
  type_ : string; [@json.key "type"]
  budget_tokens : int;
} [@@deriving of_json]

type request_fields = {
  model : string;
  messages : Melange_json.t list;
  max_tokens : int;
  system : string option; [@json.default None]
  temperature : float option; [@json.default None]
  top_p : float option; [@json.default None]
  top_k : int option; [@json.default None]
  stream : bool option; [@json.default None]
  tools : Melange_json.t list option; [@json.default None]
  tool_choice : Melange_json.t option; [@json.default None]
  stop_sequences : string list option; [@json.default None]
  thinking : thinking_json option; [@json.default None]
} [@@json.allow_extra_fields] [@@deriving of_json]

type mock_response_fields = {
  id : string;
} [@@json.allow_extra_fields] [@@deriving of_json]

let test_minimal_body () =
  let body = Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] () in
  let r = request_fields_of_json body in
  (check string) "model" "claude-sonnet-4-6" r.model;
  (check int) "default max_tokens" 4096 r.max_tokens

let test_body_with_stream () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~stream:true ()
  in
  let r = request_fields_of_json body in
  (check (option bool)) "stream" (Some true) r.stream

let test_body_with_temperature () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~temperature:0.7 ()
  in
  let r = request_fields_of_json body in
  (check (option (float 0.01))) "temperature" (Some 0.7) r.temperature

let test_body_with_thinking () =
  let budget = Ai_provider_anthropic.Thinking.budget_exn 2048 in
  let thinking : Ai_provider_anthropic.Thinking.t = { enabled = true; budget_tokens = budget } in
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~thinking ()
  in
  let r = request_fields_of_json body in
  match r.thinking with
  | None -> fail "expected thinking"
  | Some t ->
    (check string) "type" "enabled" t.type_;
    (check int) "budget" 2048 t.budget_tokens

let test_body_omits_none_fields () =
  let body = Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] () in
  let r = request_fields_of_json body in
  (check (option (float 0.01))) "no temperature" None r.temperature

let test_body_with_system () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~system:"Be helpful"
      ()
  in
  let r = request_fields_of_json body in
  (check (option string)) "system" (Some "Be helpful") r.system

(* Beta headers tests *)

let test_required_betas_thinking () =
  let betas = Ai_provider_anthropic.Beta_headers.required_betas ~thinking:true ~has_pdf:false ~tool_streaming:false in
  (check int) "1 beta" 1 (List.length betas)

let test_required_betas_all () =
  let betas = Ai_provider_anthropic.Beta_headers.required_betas ~thinking:true ~has_pdf:true ~tool_streaming:true in
  (check int) "3 betas" 3 (List.length betas)

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
    (check int) "2 unique betas" 2 (List.length parts)
  | None -> fail "expected anthropic-beta header"

(* Mock fetch test *)
let test_messages_with_mock_fetch () =
  let mock_response =
    Ai_provider_anthropic.Convert_response.anthropic_response_json_to_json
      {
        id = Some "msg_test";
        model = Some "claude-sonnet-4-6";
        content =
          [
            { type_ = "text"; text = Some "Hi"; id = None; name = None; input = None; thinking = None; signature = None };
          ];
        stop_reason = Some "end_turn";
        usage =
          { input_tokens = 5; output_tokens = 2; cache_read_input_tokens = None; cache_creation_input_tokens = None };
      }
  in
  let fetch ~url:_ ~headers:_ ~body:_ = Lwt.return mock_response in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let body = Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] () in
  let result =
    Lwt_main.run (Ai_provider_anthropic.Anthropic_api.messages ~config ~body ~extra_headers:[] ~stream:false)
  in
  match result with
  | `Json json ->
    let r = mock_response_fields_of_json json in
    (check string) "id" "msg_test" r.id
  | `Stream _ -> fail "expected Json"

let () =
  run "Anthropic_api"
    [
      ( "make_request_body",
        [
          test_case "minimal" `Quick test_minimal_body;
          test_case "stream" `Quick test_body_with_stream;
          test_case "temperature" `Quick test_body_with_temperature;
          test_case "thinking" `Quick test_body_with_thinking;
          test_case "omits_none" `Quick test_body_omits_none_fields;
          test_case "system" `Quick test_body_with_system;
        ] );
      ( "beta_headers",
        [
          test_case "thinking" `Quick test_required_betas_thinking;
          test_case "all" `Quick test_required_betas_all;
          test_case "dedup" `Quick test_merge_deduplicates;
        ] );
      "messages", [ test_case "mock_fetch" `Quick test_messages_with_mock_fetch ];
    ]
