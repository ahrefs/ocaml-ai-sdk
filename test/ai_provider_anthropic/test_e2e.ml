(** End-to-end integration test exercising the full pipeline:
    Provider abstraction -> Anthropic provider -> mock HTTP -> response parsing *)

open Melange_json.Primitives
open Alcotest

type thinking_json = {
  type_ : string; [@json.key "type"]
  budget_tokens : int;
} [@@deriving of_json]

type request_with_thinking = {
  thinking : thinking_json option; [@json.default None]
} [@@json.allow_extra_fields] [@@deriving of_json]

(* Mock responses *)
let mock_text_response =
  Yojson.Basic.from_string
    {|{
      "id": "msg_e2e_1",
      "type": "message",
      "role": "assistant",
      "content": [{"type": "text", "text": "Hello from the E2E test!"}],
      "model": "claude-sonnet-4-6",
      "stop_reason": "end_turn",
      "usage": {"input_tokens": 15, "output_tokens": 8, "cache_read_input_tokens": 5}
    }|}

let mock_thinking_response =
  Yojson.Basic.from_string
    {|{
      "id": "msg_e2e_2",
      "type": "message",
      "role": "assistant",
      "content": [
        {"type": "thinking", "thinking": "Let me reason about this...", "signature": "sig_e2e"},
        {"type": "text", "text": "The answer is 42."}
      ],
      "model": "claude-opus-4-6",
      "stop_reason": "end_turn",
      "usage": {"input_tokens": 30, "output_tokens": 25}
    }|}

let mock_tool_response =
  Yojson.Basic.from_string
    {|{
      "id": "msg_e2e_3",
      "type": "message",
      "role": "assistant",
      "content": [
        {"type": "text", "text": "Let me search for that."},
        {"type": "tool_use", "id": "toolu_e2e_1", "name": "web_search", "input": {"query": "OCaml AI SDK"}}
      ],
      "model": "claude-sonnet-4-6",
      "stop_reason": "tool_use",
      "usage": {"input_tokens": 20, "output_tokens": 18}
    }|}

(* Helper: create a provider with mock fetch *)
let make_mock_provider response =
  let fetch ~url:_ ~headers:_ ~body:_ = Lwt.return response in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-e2e-test" ~fetch () in
  let module P = struct
    let name = "anthropic"

    let language_model model_id = Ai_provider_anthropic.Anthropic_model.create ~config ~model:model_id
  end in
  (module P : Ai_provider.Provider.S)

(* Helper: make call options *)
let make_opts ?(system = "You are a helpful assistant") text =
  Ai_provider.Call_options.default
    ~prompt:
      [
        Ai_provider.Prompt.System { content = system };
        Ai_provider.Prompt.User { content = [ Text { text; provider_options = Ai_provider.Provider_options.empty } ] };
      ]

(* === Tests === *)

(* Test 1: Full generate through abstraction layer *)
let test_generate_through_abstraction () =
  let provider = make_mock_provider mock_text_response in
  (* Use the Provider abstraction to get a model *)
  let model = Ai_provider.Provider.language_model provider "claude-sonnet-4-6" in
  (* Verify model metadata through abstraction *)
  (check string) "provider" "anthropic" (Ai_provider.Language_model.provider model);
  (check string) "model_id" "claude-sonnet-4-6" (Ai_provider.Language_model.model_id model);
  (* Generate through abstraction *)
  let opts = make_opts "Hello, Claude!" in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (* Verify result through abstraction types *)
  (match result.content with
  | [ Ai_provider.Content.Text { text } ] -> (check string) "response" "Hello from the E2E test!" text
  | _ -> fail "expected single text content");
  (check string) "finish" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  (check int) "input_tokens" 15 result.usage.input_tokens;
  (check int) "output_tokens" 8 result.usage.output_tokens;
  (check (option int)) "total_tokens" (Some 23) result.usage.total_tokens

(* Test 2: Thinking/reasoning content *)
let test_thinking_response () =
  let provider = make_mock_provider mock_thinking_response in
  let model = Ai_provider.Provider.language_model provider "claude-opus-4-6" in
  let opts = make_opts "What is the meaning of life?" in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (check int) "2 content parts" 2 (List.length result.content);
  (match List.nth result.content 0 with
  | Ai_provider.Content.Reasoning { text; signature; _ } ->
    (check string) "thinking text" "Let me reason about this..." text;
    (check (option string)) "signature" (Some "sig_e2e") signature
  | _ -> fail "expected Reasoning first");
  match List.nth result.content 1 with
  | Ai_provider.Content.Text { text } -> (check string) "answer" "The answer is 42." text
  | _ -> fail "expected Text second"

(* Test 3: Tool call response *)
let test_tool_call_response () =
  let provider = make_mock_provider mock_tool_response in
  let model = Ai_provider.Provider.language_model provider "claude-sonnet-4-6" in
  let tool : Ai_provider.Tool.t =
    {
      name = "web_search";
      description = Some "Search the web";
      parameters =
        `Assoc [ "type", `String "object"; "properties", `Assoc [ "query", `Assoc [ "type", `String "string" ] ] ];
    }
  in
  let opts = { (make_opts "Search for OCaml AI SDK") with tools = [ tool ] } in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (check int) "2 content" 2 (List.length result.content);
  (check string) "finish" "tool_calls" (Ai_provider.Finish_reason.to_string result.finish_reason);
  (* Verify tool call through abstraction *)
  match List.nth result.content 1 with
  | Ai_provider.Content.Tool_call { tool_name; tool_call_id; args; _ } ->
    (check string) "tool name" "web_search" tool_name;
    (check string) "tool id" "toolu_e2e_1" tool_call_id;
    (* args is a JSON string *)
    (check bool) "has args" true (String.length args > 0)
  | _ -> fail "expected Tool_call second"

(* Test 4: Provider options flow through *)
let test_provider_options_flow () =
  let request_body = ref `Null in
  let fetch ~url:_ ~headers:_ ~body =
    request_body := Yojson.Basic.from_string body;
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  (* Set Anthropic-specific thinking options *)
  let budget = Ai_provider_anthropic.Thinking.budget_exn 2048 in
  let thinking : Ai_provider_anthropic.Thinking.t = { enabled = true; budget_tokens = budget } in
  let anthropic_opts = { Ai_provider_anthropic.Anthropic_options.default with thinking = Some thinking } in
  let provider_options = Ai_provider_anthropic.Anthropic_options.to_provider_options anthropic_opts in
  let opts = { (make_opts "Think about this") with provider_options } in
  let _result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (* Verify thinking was included in the request *)
  let r = request_with_thinking_of_json !request_body in
  match r.thinking with
  | None -> fail "expected thinking in request"
  | Some t ->
    (check string) "thinking type" "enabled" t.type_;
    (check int) "budget" 2048 t.budget_tokens

(* Test 5: Middleware applies to Anthropic model *)
let test_middleware_with_anthropic () =
  let call_count = ref 0 in
  let middleware =
    (module struct
      let wrap_generate ~generate opts =
        incr call_count;
        generate opts

      let wrap_stream ~stream opts =
        incr call_count;
        stream opts
    end : Ai_provider.Middleware.S)
  in
  let provider = make_mock_provider mock_text_response in
  let model = Ai_provider.Provider.language_model provider "claude-sonnet-4-6" in
  let wrapped = Ai_provider.Middleware.apply middleware model in
  (* Middleware preserves model identity *)
  (check string) "wrapped provider" "anthropic" (Ai_provider.Language_model.provider wrapped);
  let opts = make_opts "Hello" in
  let _result = Lwt_main.run (Ai_provider.Language_model.generate wrapped opts) in
  (check int) "middleware called" 1 !call_count

let () =
  run "E2E Integration"
    [
      ( "generate",
        [
          test_case "text_through_abstraction" `Quick test_generate_through_abstraction;
          test_case "thinking" `Quick test_thinking_response;
          test_case "tool_call" `Quick test_tool_call_response;
        ] );
      "provider_options", [ test_case "thinking_flow" `Quick test_provider_options_flow ];
      "middleware", [ test_case "with_anthropic" `Quick test_middleware_with_anthropic ];
    ]
