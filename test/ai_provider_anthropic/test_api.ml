(* make_request_body tests *)

open Melange_json.Primitives
open Alcotest

type thinking_json = {
  type_ : string; [@json.key "type"]
  budget_tokens : int option; [@json.default None]
  display : string option; [@json.default None]
}
[@@deriving of_json]

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
}
[@@json.allow_extra_fields] [@@deriving of_json]

type mock_response_fields = { id : string } [@@json.allow_extra_fields] [@@deriving of_json]

let request_json ?thinking ?output_config () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ?thinking
      ?output_config ()
  in
  Ai_provider_anthropic.Anthropic_api.request_body_to_json body

let check_json name expected actual = (check bool) name true (Yojson.Basic.equal expected actual)

let base_request_json = `Assoc [ "model", `String "claude-sonnet-4-6"; "messages", `List []; "max_tokens", `Int 4096 ]

let request_with field value =
  match base_request_json with
  | `Assoc fields -> `Assoc (fields @ [ field, value ])
  | _ -> assert false

let test_minimal_body () =
  let body = Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] () in
  let r = request_fields_of_json (Ai_provider_anthropic.Anthropic_api.request_body_to_json body) in
  (check string) "model" "claude-sonnet-4-6" r.model;
  (check int) "default max_tokens" 4096 r.max_tokens

let test_body_with_stream () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~stream:true ()
  in
  let r = request_fields_of_json (Ai_provider_anthropic.Anthropic_api.request_body_to_json body) in
  (check (option bool)) "stream" (Some true) r.stream

let test_body_with_temperature () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] ~temperature:0.7 ()
  in
  let r = request_fields_of_json (Ai_provider_anthropic.Anthropic_api.request_body_to_json body) in
  (check (option (float 0.01))) "temperature" (Some 0.7) r.temperature

let test_thinking_wire_shapes () =
  let budget = Ai_provider_anthropic.Thinking.budget_exn 2048 in
  let enabled display = Some (Ai_provider_anthropic.Thinking.Enabled { budget_tokens = budget; display }) in
  let cases =
    [
      "omitted thinking", None, base_request_json;
      ( "disabled thinking",
        Some Ai_provider_anthropic.Thinking.Disabled,
        request_with "thinking" (`Assoc [ "type", `String "disabled" ]) );
      ( "adaptive without display",
        Some (Ai_provider_anthropic.Thinking.Adaptive { display = None }),
        request_with "thinking" (`Assoc [ "type", `String "adaptive" ]) );
      ( "adaptive summarized",
        Some (Ai_provider_anthropic.Thinking.Adaptive { display = Some Ai_provider_anthropic.Thinking.Summarized }),
        request_with "thinking" (`Assoc [ "type", `String "adaptive"; "display", `String "summarized" ]) );
      ( "adaptive omitted",
        Some (Ai_provider_anthropic.Thinking.Adaptive { display = Some Ai_provider_anthropic.Thinking.Omitted }),
        request_with "thinking" (`Assoc [ "type", `String "adaptive"; "display", `String "omitted" ]) );
      ( "enabled without display",
        enabled None,
        request_with "thinking" (`Assoc [ "type", `String "enabled"; "budget_tokens", `Int 2048 ]) );
      ( "enabled summarized",
        enabled (Some Ai_provider_anthropic.Thinking.Summarized),
        request_with "thinking"
          (`Assoc [ "type", `String "enabled"; "budget_tokens", `Int 2048; "display", `String "summarized" ]) );
      ( "enabled omitted",
        enabled (Some Ai_provider_anthropic.Thinking.Omitted),
        request_with "thinking"
          (`Assoc [ "type", `String "enabled"; "budget_tokens", `Int 2048; "display", `String "omitted" ]) );
    ]
  in
  List.iter (fun (name, thinking, expected) -> check_json name expected (request_json ?thinking ())) cases

let test_output_config_wire_shapes () =
  let schema = `Assoc [ "type", `String "object" ] in
  let format : Ai_provider_anthropic.Anthropic_api.output_format = { type_ = "json_schema"; schema } in
  let config ~format ~effort : Ai_provider_anthropic.Anthropic_api.output_config = { format; effort } in
  let cases =
    [
      ( "effort only",
        config ~format:None ~effort:(Some "high"),
        request_with "output_config" (`Assoc [ "effort", `String "high" ]) );
      ( "format only",
        config ~format:(Some format) ~effort:None,
        request_with "output_config" (`Assoc [ "format", `Assoc [ "type", `String "json_schema"; "schema", schema ] ]) );
      ( "format and effort",
        config ~format:(Some format) ~effort:(Some "max"),
        request_with "output_config"
          (`Assoc [ "format", `Assoc [ "type", `String "json_schema"; "schema", schema ]; "effort", `String "max" ]) );
      "empty output_config omitted", config ~format:None ~effort:None, base_request_json;
    ]
  in
  List.iter (fun (name, output_config, expected) -> check_json name expected (request_json ~output_config ())) cases

let test_body_omits_none_fields () =
  let body = Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[] () in
  let r = request_fields_of_json (Ai_provider_anthropic.Anthropic_api.request_body_to_json body) in
  (check (option (float 0.01))) "no temperature" None r.temperature

let test_body_with_system () =
  let body =
    Ai_provider_anthropic.Anthropic_api.make_request_body ~model:"claude-sonnet-4-6" ~messages:[]
      ~system:(`String "Be helpful") ()
  in
  let r = request_fields_of_json (Ai_provider_anthropic.Anthropic_api.request_body_to_json body) in
  (check (option string)) "system" (Some "Be helpful") r.system

(* Beta headers tests *)

let test_required_betas_thinking () =
  let thinking =
    Some
      (Ai_provider_anthropic.Thinking.Enabled
         { budget_tokens = Ai_provider_anthropic.Thinking.budget_exn 1024; display = None })
  in
  let betas = Ai_provider_anthropic.Beta_headers.required_betas ~thinking ~has_pdf:false ~tool_streaming:false in
  (check int) "1 beta" 1 (List.length betas)

let test_required_betas_all () =
  let thinking =
    Some
      (Ai_provider_anthropic.Thinking.Enabled
         { budget_tokens = Ai_provider_anthropic.Thinking.budget_exn 1024; display = None })
  in
  let betas = Ai_provider_anthropic.Beta_headers.required_betas ~thinking ~has_pdf:true ~tool_streaming:true in
  (check int) "3 betas" 3 (List.length betas)

let test_required_betas_non_manual () =
  let cases =
    [
      "none", None;
      "disabled", Some Ai_provider_anthropic.Thinking.Disabled;
      "adaptive", Some (Ai_provider_anthropic.Thinking.Adaptive { display = None });
    ]
  in
  List.iter
    (fun (name, thinking) ->
      let betas = Ai_provider_anthropic.Beta_headers.required_betas ~thinking ~has_pdf:false ~tool_streaming:false in
      (check int) name 0 (List.length betas))
    cases

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
            {
              type_ = "text";
              text = Some "Hi";
              id = None;
              name = None;
              input = None;
              thinking = None;
              signature = None;
              data = None;
            };
          ];
        stop_reason = Some "end_turn";
        usage =
          {
            input_tokens = 5;
            output_tokens = 2;
            cache_read_input_tokens = None;
            cache_creation_input_tokens = None;
            cache_creation = None;
            service_tier = None;
            inference_geo = None;
          };
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
          test_case "thinking_wire_shapes" `Quick test_thinking_wire_shapes;
          test_case "output_config_wire_shapes" `Quick test_output_config_wire_shapes;
          test_case "omits_none" `Quick test_body_omits_none_fields;
          test_case "system" `Quick test_body_with_system;
        ] );
      ( "beta_headers",
        [
          test_case "thinking" `Quick test_required_betas_thinking;
          test_case "all" `Quick test_required_betas_all;
          test_case "non_manual" `Quick test_required_betas_non_manual;
          test_case "dedup" `Quick test_merge_deduplicates;
        ] );
      "messages", [ test_case "mock_fetch" `Quick test_messages_with_mock_fetch ];
    ]
