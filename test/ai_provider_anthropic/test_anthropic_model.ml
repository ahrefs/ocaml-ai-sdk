open Melange_json.Primitives
open Alcotest

type output_format_json = {
  type_ : string; [@json.key "type"]
  schema : Melange_json.t;
}
[@@json.allow_extra_fields] [@@deriving of_json]

type output_config_json = {
  format : output_format_json option; [@json.default None]
  effort : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type thinking_json = {
  type_ : string; [@json.key "type"]
  display : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type tool_json = {
  name : string;
  input_schema : Melange_json.t;
}
[@@json.allow_extra_fields] [@@deriving of_json]

type tool_choice_json = {
  type_ : string; [@json.key "type"]
  name : string option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

type system_block_json = {
  type_ : string; [@json.key "type"]
  text : string;
}
[@@json.allow_extra_fields] [@@deriving of_json]

type request_body_json = {
  system : system_block_json list option; [@json.default None]
  output_config : output_config_json option; [@json.default None]
  thinking : thinking_json option; [@json.default None]
  temperature : float option; [@json.default None]
  top_p : float option; [@json.default None]
  top_k : int option; [@json.default None]
  tools : tool_json list option; [@json.default None]
  tool_choice : tool_choice_json option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

(* Helper for tests: concatenate text from system blocks like Anthropic does. *)
let system_text_of_blocks blocks = List.map (fun (b : system_block_json) -> b.text) blocks |> String.concat ""

let mock_text_response =
  Ai_provider_anthropic.Convert_response.anthropic_response_json_to_json
    {
      id = Some "msg_test";
      model = Some "claude-sonnet-5";
      content =
        [
          {
            type_ = "text";
            text = Some "Hello from Claude!";
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
          input_tokens = 10;
          output_tokens = 5;
          cache_read_input_tokens = None;
          cache_creation_input_tokens = None;
          cache_creation = None;
          service_tier = None;
          inference_geo = None;
        };
    }

let mock_tool_response =
  Ai_provider_anthropic.Convert_response.anthropic_response_json_to_json
    {
      id = Some "msg_tool";
      model = Some "claude-sonnet-5";
      content =
        [
          {
            type_ = "text";
            text = Some "Let me search.";
            id = None;
            name = None;
            input = None;
            thinking = None;
            signature = None;
            data = None;
          };
          {
            type_ = "tool_use";
            text = None;
            id = Some "tc_1";
            name = Some "search";
            input = Some (`Assoc [ "query", `String "test" ]);
            thinking = None;
            signature = None;
            data = None;
          };
        ];
      stop_reason = Some "tool_use";
      usage =
        {
          input_tokens = 20;
          output_tokens = 15;
          cache_read_input_tokens = None;
          cache_creation_input_tokens = None;
          cache_creation = None;
          service_tier = None;
          inference_geo = None;
        };
    }

let make_config response =
  let fetch ~url:_ ~headers:_ ~body:_ = Lwt.return response in
  Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch ()

let make_opts ?(prompt_text = "Hello") () =
  Ai_provider.Call_options.default
    ~prompt:
      [
        Ai_provider.Prompt.User
          { content = [ Text { text = prompt_text; provider_options = Ai_provider.Provider_options.empty } ] };
      ]

let test_generate_text () =
  let config = make_config mock_text_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-5" in
  let opts = make_opts () in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (match result.content with
  | [ Ai_provider.Content.Text { text } ] -> (check string) "text" "Hello from Claude!" text
  | _ -> fail "expected single text");
  (check string) "finish" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  (check int) "input tokens" 10 result.usage.input_tokens

let test_generate_tool_call () =
  let config = make_config mock_tool_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-5" in
  let opts = make_opts () in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (check int) "2 content" 2 (List.length result.content);
  (check string) "finish" "tool-calls" (Ai_provider.Finish_reason.to_string result.finish_reason)

let test_generate_with_system () =
  let fetch_called = ref false in
  let fetch ~url:_ ~headers:_ ~body =
    fetch_called := true;
    let json = Yojson.Basic.from_string body in
    let r = request_body_json_of_json json in
    (* Verify system was included in request — upstream array-of-blocks form. *)
    (check (option string)) "system in body" (Some "Be helpful") (Option.map system_text_of_blocks r.system);
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-5" in
  let opts =
    Ai_provider.Call_options.default
      ~prompt:
        [
          Ai_provider.Prompt.System { content = "Be helpful"; provider_options = Ai_provider.Provider_options.empty };
          Ai_provider.Prompt.User
            { content = [ Text { text = "Hi"; provider_options = Ai_provider.Provider_options.empty } ] };
        ]
  in
  let _result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (check bool) "fetch called" true !fetch_called

(* Object_json None on a capable model: no native enforcement possible (schema required),
   warning emitted, nothing added to system/output_config/tools. *)
let test_object_json_no_schema () =
  let fetch ~url:_ ~headers:_ ~body =
    let json = Yojson.Basic.from_string body in
    let r = request_body_json_of_json json in
    (check (option string)) "no system injected" None (Option.map system_text_of_blocks r.system);
    (check bool) "no output_config" true (Option.is_none r.output_config);
    (check bool) "no synthetic tool" true (Option.is_none r.tools);
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-5" in
  let opts = { (make_opts ()) with mode = Object_json None } in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (check bool) "warning emitted" true (List.length result.warnings > 0)

(* Object_json (Some schema) on a native-capable model (Sonnet 5): send output_config.format,
   do not touch the system prompt or add a fallback tool. *)
let test_object_json_with_schema_native () =
  let schema_json =
    `Assoc [ "type", `String "object"; "properties", `Assoc [ "name", `Assoc [ "type", `String "string" ] ] ]
  in
  let schema : Ai_provider.Mode.json_schema = { name = "person"; schema = schema_json } in
  let fetch ~url:_ ~headers:_ ~body =
    let json = Yojson.Basic.from_string body in
    let r = request_body_json_of_json json in
    (check (option string)) "no system injected" None (Option.map system_text_of_blocks r.system);
    let oc =
      match r.output_config with
      | Some oc -> oc
      | None -> fail "expected output_config"
    in
    let format =
      match oc.format with
      | Some format -> format
      | None -> fail "expected output_config.format"
    in
    (check string) "format type" "json_schema" format.type_;
    (check string) "schema json" (Yojson.Basic.to_string schema_json) (Yojson.Basic.to_string format.schema);
    (check (option string)) "no effort" None oc.effort;
    (check bool) "no fallback tool" true (Option.is_none r.tools);
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-5" in
  let opts = { (make_opts ()) with mode = Object_json (Some schema) } in
  let _result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  ()

let test_provider_options_request_body () =
  let captured_body = ref None in
  let captured_headers = ref [] in
  let fetch ~url:_ ~headers ~body =
    captured_headers := headers;
    captured_body := Some (Yojson.Basic.from_string body);
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-5" in
  let thinking = Ai_provider_anthropic.Thinking.Adaptive { display = Some Ai_provider_anthropic.Thinking.Summarized } in
  let anthropic_opts =
    {
      Ai_provider_anthropic.Anthropic_options.default with
      thinking = Some thinking;
      effort = Some Ai_provider_anthropic.Effort.High;
    }
  in
  let opts =
    {
      (make_opts ()) with
      provider_options = Ai_provider_anthropic.Anthropic_options.to_provider_options anthropic_opts;
    }
  in
  let _result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  let actual =
    match !captured_body with
    | Some body -> body
    | None -> fail "fetch was not called"
  in
  let expected =
    `Assoc
      [
        "model", `String "claude-sonnet-5";
        ( "messages",
          `List
            [
              `Assoc
                [
                  "role", `String "user";
                  "content", `List [ `Assoc [ "type", `String "text"; "text", `String "Hello" ] ];
                ];
            ] );
        "tool_choice", `Assoc [ "type", `String "auto" ];
        "max_tokens", `Int 128000;
        "thinking", `Assoc [ "type", `String "adaptive"; "display", `String "summarized" ];
        "output_config", `Assoc [ "effort", `String "high" ];
      ]
  in
  (check bool) "exact provider-options body" true (Yojson.Basic.equal expected actual);
  (check (option string))
    "adaptive has no thinking beta" (Some "fine-grained-tool-streaming-2025-05-14")
    (List.assoc_opt "anthropic-beta" !captured_headers)

let anthropic_provider_options ?thinking ?effort () =
  let opts = { Ai_provider_anthropic.Anthropic_options.default with thinking; effort } in
  Ai_provider_anthropic.Anthropic_options.to_provider_options opts

let assert_invalid_argument f =
  try
    f ();
    fail "expected Invalid_argument"
  with Invalid_argument _ -> ()

let reject_options model_id provider_options =
  let config = make_config mock_text_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:model_id in
  let opts = { (make_opts ()) with provider_options } in
  assert_invalid_argument (fun () -> ignore (Lwt_main.run (Ai_provider.Language_model.generate model opts)))

let warning_features warnings =
  List.filter_map
    (function
      | Ai_provider.Warning.Unsupported_feature { feature; _ } -> Some feature
      | Ai_provider.Warning.Other _ -> None)
    warnings

let capture_generate ?(model_id = "claude-opus-5") ?provider_options ?temperature ?top_p ?top_k () =
  let captured_body = ref None in
  let fetch ~url:_ ~headers:_ ~body =
    captured_body := Some (Yojson.Basic.from_string body);
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:model_id in
  let opts =
    {
      (make_opts ()) with
      provider_options = Option.value provider_options ~default:Ai_provider.Provider_options.empty;
      temperature;
      top_p;
      top_k;
    }
  in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  let body =
    match !captured_body with
    | Some body -> request_body_json_of_json body
    | None -> fail "fetch was not called"
  in
  body, result

let test_policy_rejects_invalid_combinations () =
  let budget = Ai_provider_anthropic.Thinking.budget_exn 1024 in
  let manual = Ai_provider_anthropic.Thinking.Enabled { budget_tokens = budget; display = None } in
  reject_options "claude-fable-5" (anthropic_provider_options ~thinking:manual ());
  reject_options "claude-fable-5" (anthropic_provider_options ~thinking:Ai_provider_anthropic.Thinking.Disabled ())

let test_policy_rejects_forced_tool_choice_with_manual_thinking () =
  let budget = Ai_provider_anthropic.Thinking.budget_exn 1024 in
  let manual = Ai_provider_anthropic.Thinking.Enabled { budget_tokens = budget; display = None } in
  let config = make_config mock_text_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-haiku-4-5" in
  let opts =
    {
      (make_opts ()) with
      provider_options = anthropic_provider_options ~thinking:manual ();
      tool_choice = Some (Ai_provider.Tool_choice.Specific { tool_name = "search" });
    }
  in
  assert_invalid_argument (fun () -> ignore (Lwt_main.run (Ai_provider.Language_model.generate model opts)))

let test_policy_normalizes_sampling_parameters () =
  let body, result = capture_generate ~temperature:0.3 ~top_p:0.8 ~top_k:10 () in
  (check (option (float 0.01))) "temperature removed" None body.temperature;
  (check (option (float 0.01))) "top_p removed" None body.top_p;
  (check (option int)) "top_k removed" None body.top_k;
  let features = warning_features result.warnings in
  List.iter
    (fun feature -> (check bool) (feature ^ " warning") true (List.mem feature features))
    [ "temperature"; "top_p"; "top_k" ]

let test_policy_preserves_supported_top_p_with_thinking () =
  (* Haiku 4.5 accepts sampling parameters and supports manual thinking only. *)
  let provider_options =
    anthropic_provider_options
      ~thinking:
        (Ai_provider_anthropic.Thinking.Enabled
           { budget_tokens = Ai_provider_anthropic.Thinking.budget_exn 1024; display = None })
      ()
  in
  let body, result = capture_generate ~model_id:"claude-haiku-4-5" ~provider_options ~top_p:0.95 () in
  (check (option (float 0.01))) "top_p preserved" (Some 0.95) body.top_p;
  (check bool) "no top_p warning" false (List.mem "top_p" (warning_features result.warnings))

let test_policy_lowers_disabled_effort () =
  let provider_options =
    anthropic_provider_options ~thinking:Ai_provider_anthropic.Thinking.Disabled
      ~effort:Ai_provider_anthropic.Effort.Max ()
  in
  let body, result = capture_generate ~provider_options () in
  (match body.thinking with
  | Some thinking -> (check string) "thinking" "disabled" thinking.type_
  | None -> fail "expected disabled thinking");
  (match body.output_config with
  | Some { effort = Some effort; _ } -> (check string) "lowered effort" "high" effort
  | _ -> fail "expected lowered effort");
  (check bool) "normalization warning" true
    (List.mem "providerOptions.anthropic.effort" (warning_features result.warnings))

let test_policy_preserves_custom_model_options () =
  let provider_options =
    anthropic_provider_options ~thinking:Ai_provider_anthropic.Thinking.Disabled
      ~effort:Ai_provider_anthropic.Effort.Max ()
  in
  let body, _result =
    capture_generate ~model_id:"my-anthropic-compatible-model" ~provider_options ~temperature:0.3 ~top_p:0.8 ~top_k:10
      ()
  in
  (check (option (float 0.01))) "custom temperature" (Some 0.3) body.temperature;
  (check (option (float 0.01))) "custom top_p" (Some 0.8) body.top_p;
  (check (option int)) "custom top_k" (Some 10) body.top_k;
  match body.output_config with
  | Some { effort = Some effort; _ } -> (check string) "custom effort" "max" effort
  | _ -> fail "expected custom effort"

(* Assert that Object_json (Some schema) on [model_id] takes the tool-fallback path:
   synthesise the [json] tool, force tool_choice to it, leave system untouched and
   output_config absent. Parameterised by model id so we can exercise multiple
   unsupported models (legacy + unknown [Custom]). *)
let assert_fallback_path model_id () =
  let schema : Ai_provider.Mode.json_schema =
    {
      name = "person";
      schema = `Assoc [ "type", `String "object"; "properties", `Assoc [ "name", `Assoc [ "type", `String "string" ] ] ];
    }
  in
  let fetch ~url:_ ~headers:_ ~body =
    let json = Yojson.Basic.from_string body in
    let r = request_body_json_of_json json in
    (check (option string)) "no system injected" None (Option.map system_text_of_blocks r.system);
    (check bool) "no output_config" true (Option.is_none r.output_config);
    let tools =
      match r.tools with
      | Some ts -> ts
      | None -> fail "expected synthetic tool"
    in
    (check int) "one tool" 1 (List.length tools);
    (check string) "tool name" "json" (List.hd tools).name;
    let tc =
      match r.tool_choice with
      | Some tc -> tc
      | None -> fail "expected forced tool_choice"
    in
    (check string) "tool_choice type" "tool" tc.type_;
    (check (option string)) "tool_choice name" (Some "json") tc.name;
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:model_id in
  let opts = { (make_opts ()) with mode = Object_json (Some schema) } in
  let _result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  ()

(* Unknown / Custom model id: [Model_catalog] flags [supports_structured_output = false]
   as its safe default. This test locks that default in — if it ever flips to [true],
   calls to genuinely-unsupported models would 400 at runtime. *)
let test_object_json_with_schema_tool_fallback_custom () = assert_fallback_path "claude-future-unknown-model-9999" ()

(* Object_json None with an existing system prompt: system prompt is passed through unchanged
   (the old code appended a JSON instruction; we no longer do that). *)
let test_object_json_preserves_existing_system () =
  let fetch ~url:_ ~headers:_ ~body =
    let json = Yojson.Basic.from_string body in
    let r = request_body_json_of_json json in
    (check (option string)) "system unchanged" (Some "Be helpful") (Option.map system_text_of_blocks r.system);
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-5" in
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [
             Ai_provider.Prompt.System { content = "Be helpful"; provider_options = Ai_provider.Provider_options.empty };
             Ai_provider.Prompt.User
               { content = [ Text { text = "Hi"; provider_options = Ai_provider.Provider_options.empty } ] };
           ])
      with
      mode = Object_json None;
    }
  in
  let _result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  ()

let test_warns_frequency_penalty () =
  let config = make_config mock_text_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-5" in
  let opts = { (make_opts ()) with frequency_penalty = Some 0.5 } in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (check bool) "has warnings" true (List.length result.warnings > 0)

let test_model_accessors () =
  let config = make_config mock_text_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-5" in
  (check string) "provider" "anthropic" (Ai_provider.Language_model.provider model);
  (check string) "model_id" "claude-sonnet-5" (Ai_provider.Language_model.model_id model);
  (check string) "spec" "V3" (Ai_provider.Language_model.specification_version model)

let () =
  run "Anthropic_model"
    [
      ( "generate",
        [
          test_case "text" `Quick test_generate_text;
          test_case "tool_call" `Quick test_generate_tool_call;
          test_case "with_system" `Quick test_generate_with_system;
          test_case "warns_frequency_penalty" `Quick test_warns_frequency_penalty;
        ] );
      ( "object_json",
        [
          test_case "no_schema" `Quick test_object_json_no_schema;
          test_case "with_schema_native" `Quick test_object_json_with_schema_native;
          test_case "provider_options_request_body" `Quick test_provider_options_request_body;
          test_case "policy_rejects_invalid" `Quick test_policy_rejects_invalid_combinations;
          test_case "policy_rejects_forced_tool" `Quick test_policy_rejects_forced_tool_choice_with_manual_thinking;
          test_case "policy_normalizes_sampling" `Quick test_policy_normalizes_sampling_parameters;
          test_case "policy_preserves_supported_top_p" `Quick test_policy_preserves_supported_top_p_with_thinking;
          test_case "policy_lowers_disabled_effort" `Quick test_policy_lowers_disabled_effort;
          test_case "policy_custom_passthrough" `Quick test_policy_preserves_custom_model_options;
          test_case "with_schema_tool_fallback (custom model)" `Quick test_object_json_with_schema_tool_fallback_custom;
          test_case "preserves_existing_system" `Quick test_object_json_preserves_existing_system;
        ] );
      "accessors", [ test_case "model_accessors" `Quick test_model_accessors ];
    ]
