open Melange_json.Primitives
open Alcotest

type output_format_json = {
  type_ : string; [@json.key "type"]
  schema : Melange_json.t;
}
[@@json.allow_extra_fields] [@@deriving of_json]

type output_config_json = { format : output_format_json } [@@json.allow_extra_fields] [@@deriving of_json]

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

type request_body_json = {
  system : string option; [@json.default None]
  output_config : output_config_json option; [@json.default None]
  tools : tool_json list option; [@json.default None]
  tool_choice : tool_choice_json option; [@json.default None]
}
[@@json.allow_extra_fields] [@@deriving of_json]

let mock_text_response =
  Ai_provider_anthropic.Convert_response.anthropic_response_json_to_json
    {
      id = Some "msg_test";
      model = Some "claude-sonnet-4-6";
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
      model = Some "claude-sonnet-4-6";
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
          };
          {
            type_ = "tool_use";
            text = None;
            id = Some "tc_1";
            name = Some "search";
            input = Some (`Assoc [ "query", `String "test" ]);
            thinking = None;
            signature = None;
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
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let opts = make_opts () in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (match result.content with
  | [ Ai_provider.Content.Text { text } ] -> (check string) "text" "Hello from Claude!" text
  | _ -> fail "expected single text");
  (check string) "finish" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  (check int) "input tokens" 10 result.usage.input_tokens

let test_generate_tool_call () =
  let config = make_config mock_tool_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
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
    (* Verify system was included in request *)
    (check (option string)) "system in body" (Some "Be helpful") r.system;
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let opts =
    Ai_provider.Call_options.default
      ~prompt:
        [
          Ai_provider.Prompt.System { content = "Be helpful" };
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
    (check (option string)) "no system injected" None r.system;
    (check bool) "no output_config" true (Option.is_none r.output_config);
    (check bool) "no synthetic tool" true (Option.is_none r.tools);
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let opts = { (make_opts ()) with mode = Object_json None } in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (check bool) "warning emitted" true (List.length result.warnings > 0)

(* Object_json (Some schema) on a native-capable model (Sonnet 4.6): send output_config.format,
   do not touch the system prompt or add a fallback tool. *)
let test_object_json_with_schema_native () =
  let schema_json =
    `Assoc [ "type", `String "object"; "properties", `Assoc [ "name", `Assoc [ "type", `String "string" ] ] ]
  in
  let schema : Ai_provider.Mode.json_schema = { name = "person"; schema = schema_json } in
  let fetch ~url:_ ~headers:_ ~body =
    let json = Yojson.Basic.from_string body in
    let r = request_body_json_of_json json in
    (check (option string)) "no system injected" None r.system;
    let oc =
      match r.output_config with
      | Some oc -> oc
      | None -> fail "expected output_config"
    in
    (check string) "format type" "json_schema" oc.format.type_;
    (check string) "schema json" (Yojson.Basic.to_string schema_json) (Yojson.Basic.to_string oc.format.schema);
    (check bool) "no fallback tool" true (Option.is_none r.tools);
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let opts = { (make_opts ()) with mode = Object_json (Some schema) } in
  let _result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  ()

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
    (check (option string)) "no system injected" None r.system;
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

let test_object_json_with_schema_tool_fallback_legacy () = assert_fallback_path "claude-sonnet-4-0" ()

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
    (check (option string)) "system unchanged" (Some "Be helpful") r.system;
    Lwt.return mock_text_response
  in
  let config = Ai_provider_anthropic.Config.create ~api_key:"sk-test" ~fetch () in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [
             Ai_provider.Prompt.System { content = "Be helpful" };
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
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  let opts = { (make_opts ()) with frequency_penalty = Some 0.5 } in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (check bool) "has warnings" true (List.length result.warnings > 0)

let test_model_accessors () =
  let config = make_config mock_text_response in
  let model = Ai_provider_anthropic.Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
  (check string) "provider" "anthropic" (Ai_provider.Language_model.provider model);
  (check string) "model_id" "claude-sonnet-4-6" (Ai_provider.Language_model.model_id model);
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
          test_case "with_schema_tool_fallback (legacy model)" `Quick test_object_json_with_schema_tool_fallback_legacy;
          test_case "with_schema_tool_fallback (custom model)" `Quick test_object_json_with_schema_tool_fallback_custom;
          test_case "preserves_existing_system" `Quick test_object_json_preserves_existing_system;
        ] );
      "accessors", [ test_case "model_accessors" `Quick test_model_accessors ];
    ]
