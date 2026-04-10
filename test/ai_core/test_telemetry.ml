open Alcotest

(* ---- Settings ---- *)

let test_default_settings () =
  let t = Ai_core.Telemetry.create () in
  (check bool) "disabled by default" false (Ai_core.Telemetry.enabled t);
  (check bool) "record_inputs default" true (Ai_core.Telemetry.record_inputs t);
  (check bool) "record_outputs default" true (Ai_core.Telemetry.record_outputs t);
  (check (option string)) "no function_id" None (Ai_core.Telemetry.function_id t);
  (check int) "no metadata" 0 (List.length (Ai_core.Telemetry.metadata t))

let test_custom_settings () =
  let t =
    Ai_core.Telemetry.create ~enabled:true ~record_inputs:false ~record_outputs:false ~function_id:"my-chat"
      ~metadata:[ "user_id", `String "u-123"; "env", `String "prod" ]
      ()
  in
  (check bool) "enabled" true (Ai_core.Telemetry.enabled t);
  (check bool) "record_inputs" false (Ai_core.Telemetry.record_inputs t);
  (check bool) "record_outputs" false (Ai_core.Telemetry.record_outputs t);
  (check (option string)) "function_id" (Some "my-chat") (Ai_core.Telemetry.function_id t);
  (check int) "metadata" 2 (List.length (Ai_core.Telemetry.metadata t))

(* ---- Attribute Selection ---- *)

let test_select_attributes_disabled () =
  let t = Ai_core.Telemetry.create () in
  let attrs =
    Ai_core.Telemetry.select_attributes t
      [
        "always", Ai_core.Telemetry.Always (`String "yes");
        "input", Ai_core.Telemetry.Input (fun () -> `String "prompt");
        "output", Ai_core.Telemetry.Output (fun () -> `String "response");
      ]
  in
  (check int) "empty when disabled" 0 (List.length attrs)

let test_select_attributes_enabled_all () =
  let t = Ai_core.Telemetry.create ~enabled:true () in
  let attrs =
    Ai_core.Telemetry.select_attributes t
      [
        "always", Ai_core.Telemetry.Always (`String "yes");
        "input", Ai_core.Telemetry.Input (fun () -> `String "prompt");
        "output", Ai_core.Telemetry.Output (fun () -> `String "response");
      ]
  in
  (check int) "all 3 recorded" 3 (List.length attrs)

let test_select_attributes_no_inputs () =
  let t = Ai_core.Telemetry.create ~enabled:true ~record_inputs:false () in
  let attrs =
    Ai_core.Telemetry.select_attributes t
      [
        "always", Ai_core.Telemetry.Always (`String "yes");
        "input", Ai_core.Telemetry.Input (fun () -> `String "prompt");
        "output", Ai_core.Telemetry.Output (fun () -> `String "response");
      ]
  in
  (check int) "2 recorded (no input)" 2 (List.length attrs);
  (check bool) "no input key" true (not (List.mem_assoc "input" attrs))

let test_select_attributes_no_outputs () =
  let t = Ai_core.Telemetry.create ~enabled:true ~record_outputs:false () in
  let attrs =
    Ai_core.Telemetry.select_attributes t
      [
        "always", Ai_core.Telemetry.Always (`String "yes");
        "input", Ai_core.Telemetry.Input (fun () -> `String "prompt");
        "output", Ai_core.Telemetry.Output (fun () -> `String "response");
      ]
  in
  (check int) "2 recorded (no output)" 2 (List.length attrs);
  (check bool) "no output key" true (not (List.mem_assoc "output" attrs))

(* ---- Operation Name Assembly ---- *)

let test_assemble_operation_name_no_function_id () =
  let t = Ai_core.Telemetry.create ~enabled:true () in
  let attrs = Ai_core.Telemetry.assemble_operation_name ~operation_id:"ai.generateText" t in
  (check string) "operation.name" "ai.generateText"
    (match List.assoc_opt "operation.name" attrs with
    | Some (`String s) -> s
    | _ -> "");
  (check bool) "no resource.name" true (not (List.mem_assoc "resource.name" attrs));
  (check string) "ai.operationId" "ai.generateText"
    (match List.assoc_opt "ai.operationId" attrs with
    | Some (`String s) -> s
    | _ -> "");
  (check bool) "no ai.telemetry.functionId" true (not (List.mem_assoc "ai.telemetry.functionId" attrs))

let test_assemble_operation_name_with_function_id () =
  let t = Ai_core.Telemetry.create ~enabled:true ~function_id:"chat-endpoint" () in
  let attrs = Ai_core.Telemetry.assemble_operation_name ~operation_id:"ai.generateText" t in
  (check string) "operation.name" "ai.generateText chat-endpoint"
    (match List.assoc_opt "operation.name" attrs with
    | Some (`String s) -> s
    | _ -> "");
  (check string) "resource.name" "chat-endpoint"
    (match List.assoc_opt "resource.name" attrs with
    | Some (`String s) -> s
    | _ -> "");
  (check string) "ai.operationId" "ai.generateText"
    (match List.assoc_opt "ai.operationId" attrs with
    | Some (`String s) -> s
    | _ -> "");
  (check string) "ai.telemetry.functionId" "chat-endpoint"
    (match List.assoc_opt "ai.telemetry.functionId" attrs with
    | Some (`String s) -> s
    | _ -> "")

(* ---- Base Telemetry Attributes ---- *)

let test_base_attributes () =
  let t = Ai_core.Telemetry.create ~enabled:true ~metadata:[ "env", `String "prod"; "version", `Int 3 ] () in
  let attrs =
    Ai_core.Telemetry.base_attributes ~provider:"anthropic" ~model_id:"claude-sonnet-4-6" ~settings_attrs:[]
      ~headers:[ "x-custom", "val" ]
      t
  in
  (check string) "provider" "anthropic"
    (match List.assoc_opt "ai.model.provider" attrs with
    | Some (`String s) -> s
    | _ -> "");
  (check string) "model" "claude-sonnet-4-6"
    (match List.assoc_opt "ai.model.id" attrs with
    | Some (`String s) -> s
    | _ -> "");
  (check string) "metadata.env" "prod"
    (match List.assoc_opt "ai.telemetry.metadata.env" attrs with
    | Some (`String s) -> s
    | _ -> "");
  (check int) "metadata.version" 3
    (match List.assoc_opt "ai.telemetry.metadata.version" attrs with
    | Some (`Int n) -> n
    | _ -> 0);
  (check string) "header" "val"
    (match List.assoc_opt "ai.request.headers.x-custom" attrs with
    | Some (`String s) -> s
    | _ -> "")

let test_base_attributes_with_settings () =
  let t = Ai_core.Telemetry.create ~enabled:true () in
  let settings_attrs = [ "ai.settings.maxOutputTokens", `Int 1000; "ai.settings.temperature", `Float 0.7 ] in
  let attrs =
    Ai_core.Telemetry.base_attributes ~provider:"anthropic" ~model_id:"claude-sonnet-4-6" ~settings_attrs ~headers:[] t
  in
  (check int) "maxOutputTokens" 1000
    (match List.assoc_opt "ai.settings.maxOutputTokens" attrs with
    | Some (`Int n) -> n
    | _ -> 0);
  (check (float 0.01))
    "temperature" 0.7
    (match List.assoc_opt "ai.settings.temperature" attrs with
    | Some (`Float f) -> f
    | _ -> 0.0)

(* ---- Settings Attributes ---- *)

let test_settings_attributes_empty () =
  let attrs = Ai_core.Telemetry.settings_attributes () in
  (check int) "empty when no options" 0 (List.length attrs)

let test_settings_attributes_some () =
  let attrs = Ai_core.Telemetry.settings_attributes ~max_output_tokens:1000 ~temperature:0.7 ~seed:42 () in
  (check int) "3 attrs" 3 (List.length attrs);
  (check int) "maxOutputTokens" 1000
    (match List.assoc_opt "ai.settings.maxOutputTokens" attrs with
    | Some (`Int n) -> n
    | _ -> 0);
  (check (float 0.01))
    "temperature" 0.7
    (match List.assoc_opt "ai.settings.temperature" attrs with
    | Some (`Float f) -> f
    | _ -> 0.0);
  (check int) "seed" 42
    (match List.assoc_opt "ai.settings.seed" attrs with
    | Some (`Int n) -> n
    | _ -> 0)

(* ---- Lwt Span Helper ---- *)

let test_with_span_lwt_success () =
  let result =
    Lwt_main.run (Ai_core.Telemetry.with_span_lwt ~data:(fun () -> []) "test.span" (fun _sp -> Lwt.return 42))
  in
  (check int) "returns value" 42 result

let test_with_span_lwt_exception () =
  let raised =
    try
      ignore
        (Lwt_main.run (Ai_core.Telemetry.with_span_lwt ~data:(fun () -> []) "test.span" (fun _sp -> failwith "boom")));
      false
    with Failure msg -> String.equal msg "boom"
  in
  (check bool) "re-raised" true raised

(* ---- Integration Callbacks ---- *)

let test_notify_integrations () =
  let call_log = ref [] in
  let integration1 : Ai_core.Telemetry.integration =
    {
      on_start =
        Some
          (fun _event ->
            call_log := "i1:start" :: !call_log;
            Lwt.return_unit);
      on_step_finish = None;
      on_tool_call_start = None;
      on_tool_call_finish = None;
      on_finish = None;
    }
  in
  let integration2 : Ai_core.Telemetry.integration =
    {
      on_start =
        Some
          (fun _event ->
            call_log := "i2:start" :: !call_log;
            Lwt.return_unit);
      on_step_finish = None;
      on_tool_call_start = None;
      on_tool_call_finish = None;
      on_finish = None;
    }
  in
  let t = Ai_core.Telemetry.create ~enabled:true ~integrations:[ integration1; integration2 ] () in
  let event : Ai_core.Telemetry.on_start_event =
    {
      model = { provider = "mock"; model_id = "mock-v1" };
      messages = [];
      tools = [];
      function_id = None;
      metadata = [];
    }
  in
  Lwt_main.run (Ai_core.Telemetry.notify_on_start t event);
  (check int) "both called" 2 (List.length !call_log);
  (check string) "order" "i2:start" (List.hd !call_log)

let test_integration_error_ignored () =
  let after_called = ref false in
  let bad_integration : Ai_core.Telemetry.integration =
    {
      on_start = Some (fun _event -> failwith "integration error");
      on_step_finish = None;
      on_tool_call_start = None;
      on_tool_call_finish = None;
      on_finish = None;
    }
  in
  let good_integration : Ai_core.Telemetry.integration =
    {
      on_start =
        Some
          (fun _event ->
            after_called := true;
            Lwt.return_unit);
      on_step_finish = None;
      on_tool_call_start = None;
      on_tool_call_finish = None;
      on_finish = None;
    }
  in
  let t = Ai_core.Telemetry.create ~enabled:true ~integrations:[ bad_integration; good_integration ] () in
  let event : Ai_core.Telemetry.on_start_event =
    {
      model = { provider = "mock"; model_id = "mock-v1" };
      messages = [];
      tools = [];
      function_id = None;
      metadata = [];
    }
  in
  Lwt_main.run (Ai_core.Telemetry.notify_on_start t event);
  (check bool) "good integration still called" true !after_called

(* ---- Global Integration Registry ---- *)

let test_global_integration () =
  let called = ref false in
  let global : Ai_core.Telemetry.integration =
    {
      on_start =
        Some
          (fun _event ->
            called := true;
            Lwt.return_unit);
      on_step_finish = None;
      on_tool_call_start = None;
      on_tool_call_finish = None;
      on_finish = None;
    }
  in
  Ai_core.Telemetry.register_global_integration global;
  let t = Ai_core.Telemetry.create ~enabled:true () in
  let event : Ai_core.Telemetry.on_start_event =
    {
      model = { provider = "mock"; model_id = "mock-v1" };
      messages = [];
      tools = [];
      function_id = None;
      metadata = [];
    }
  in
  Lwt_main.run (Ai_core.Telemetry.notify_on_start t event);
  (check bool) "global called" true !called;
  Ai_core.Telemetry.clear_global_integrations ()

let test_no_integration_record () =
  let i = Ai_core.Telemetry.no_integration in
  (check bool) "no on_start" true (Option.is_none i.on_start);
  (check bool) "no on_step_finish" true (Option.is_none i.on_step_finish);
  (check bool) "no on_tool_call_start" true (Option.is_none i.on_tool_call_start);
  (check bool) "no on_tool_call_finish" true (Option.is_none i.on_tool_call_finish);
  (check bool) "no on_finish" true (Option.is_none i.on_finish)

(* ---- Shared Helpers ---- *)

let test_maybe_span_disabled () =
  let called = ref false in
  let _result =
    Lwt_main.run
      (Ai_core.Telemetry.maybe_span None "test.span"
         ~data:(fun () -> [])
         (fun _sp ->
           called := true;
           Lwt.return 42))
  in
  (check bool) "function called" true !called

let test_maybe_span_disabled_explicit () =
  let t = Ai_core.Telemetry.create ~enabled:false () in
  let result =
    Lwt_main.run (Ai_core.Telemetry.maybe_span (Some t) "test.span" ~data:(fun () -> []) (fun _sp -> Lwt.return 99))
  in
  (check int) "returns value" 99 result

let test_maybe_notify_disabled () =
  let called = ref false in
  Lwt_main.run
    (Ai_core.Telemetry.maybe_notify None (fun _t ->
       called := true;
       Lwt.return_unit));
  (check bool) "not called" false !called

let test_maybe_notify_enabled () =
  let called = ref false in
  let t = Ai_core.Telemetry.create ~enabled:true () in
  Lwt_main.run
    (Ai_core.Telemetry.maybe_notify (Some t) (fun _t ->
       called := true;
       Lwt.return_unit));
  (check bool) "called" true !called

let test_make_model_info () =
  let mi = Ai_core.Telemetry.make_model_info ~provider:"anthropic" ~model_id:"claude-4" in
  (check string) "provider" "anthropic" mi.provider;
  (check string) "model_id" "claude-4" mi.model_id

let test_tool_calls_to_json_string () =
  let tcs : Ai_core.Generate_text_result.tool_call list =
    [ { tool_call_id = "tc_1"; tool_name = "search"; args = `Assoc [ "q", `String "test" ] } ]
  in
  let json = Ai_core.Telemetry.tool_calls_to_json_string tcs in
  let parsed = Yojson.Basic.from_string json in
  match parsed with
  | `List [ `Assoc pairs ] ->
    (check string) "toolCallId" "tc_1"
      (match List.assoc_opt "toolCallId" pairs with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "toolName" "search"
      (match List.assoc_opt "toolName" pairs with
      | Some (`String s) -> s
      | _ -> "")
  | _ -> Alcotest.fail "expected list with one element"

let () =
  run "Telemetry"
    [
      ( "settings",
        [
          test_case "default settings" `Quick test_default_settings;
          test_case "custom settings" `Quick test_custom_settings;
        ] );
      ( "attribute selection",
        [
          test_case "disabled returns empty" `Quick test_select_attributes_disabled;
          test_case "enabled records all" `Quick test_select_attributes_enabled_all;
          test_case "no inputs" `Quick test_select_attributes_no_inputs;
          test_case "no outputs" `Quick test_select_attributes_no_outputs;
        ] );
      ( "operation name",
        [
          test_case "without function_id" `Quick test_assemble_operation_name_no_function_id;
          test_case "with function_id" `Quick test_assemble_operation_name_with_function_id;
        ] );
      ( "base attributes",
        [
          test_case "model, metadata, headers" `Quick test_base_attributes;
          test_case "with settings" `Quick test_base_attributes_with_settings;
        ] );
      ( "settings attributes",
        [
          test_case "empty" `Quick test_settings_attributes_empty;
          test_case "some values" `Quick test_settings_attributes_some;
        ] );
      ( "with_span_lwt",
        [
          test_case "success" `Quick test_with_span_lwt_success;
          test_case "exception" `Quick test_with_span_lwt_exception;
        ] );
      ( "integrations",
        [
          test_case "notify multiple" `Quick test_notify_integrations;
          test_case "error ignored" `Quick test_integration_error_ignored;
          test_case "global integration" `Quick test_global_integration;
          test_case "no_integration record" `Quick test_no_integration_record;
        ] );
      ( "shared helpers",
        [
          test_case "maybe_span disabled (None)" `Quick test_maybe_span_disabled;
          test_case "maybe_span disabled (explicit)" `Quick test_maybe_span_disabled_explicit;
          test_case "maybe_notify disabled" `Quick test_maybe_notify_disabled;
          test_case "maybe_notify enabled" `Quick test_maybe_notify_enabled;
          test_case "make_model_info" `Quick test_make_model_info;
          test_case "tool_calls_to_json_string" `Quick test_tool_calls_to_json_string;
        ] );
    ]
