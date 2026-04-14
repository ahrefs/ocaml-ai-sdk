open Alcotest

(* ---- Mock model for span tests ---- *)

let make_mock_model response_text =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-v1"

    let generate _opts =
      Lwt.return
        {
          Ai_provider.Generate_result.content = [ Ai_provider.Content.Text { text = response_text } ];
          finish_reason = Ai_provider.Finish_reason.Stop;
          usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
          warnings = [];
          provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = Some "r1"; model = Some "mock-v1"; headers = []; body = `Null };
        }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

(* ---- Test collector for span assertions ---- *)

type Trace_core.span += Test_span of int

let make_test_collector () =
  let spans : (int * string) list ref = ref [] in
  let span_data : (int, (string * Trace_core.user_data) list ref) Hashtbl.t = Hashtbl.create 16 in
  let next_id = ref 0 in
  let callbacks : unit Trace_core.Collector.Callbacks.t =
    Trace_core.Collector.Callbacks.make
      ~enter_span:(fun () ~__FUNCTION__:_ ~__FILE__:_ ~__LINE__:_ ~level:_ ~params:_ ~data ~parent:_ name ->
        let id = !next_id in
        incr next_id;
        spans := (id, name) :: !spans;
        Hashtbl.replace span_data id (ref data);
        Test_span id)
      ~exit_span:(fun () _sp -> ())
      ~add_data_to_span:(fun () sp data ->
        match sp with
        | Test_span id ->
          (match Hashtbl.find_opt span_data id with
          | Some data_ref -> data_ref := !data_ref @ data
          | None -> ())
        | _ -> ())
      ~message:(fun () ~level:_ ~params:_ ~data:_ ~span:_ _msg -> ())
      ~metric:(fun () ~level:_ ~params:_ ~data:_ _name _metric -> ())
      ()
  in
  let collector = Trace_core.Collector.C_some ((), callbacks) in
  let get_span_names () = List.rev_map snd !spans in
  let get_span_data name =
    match List.find_opt (fun (_, n) -> String.equal n name) !spans with
    | Some (id, _) ->
      (match Hashtbl.find_opt span_data id with
      | Some data_ref -> !data_ref
      | None -> [])
    | None -> []
  in
  collector, get_span_names, get_span_data

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

let test_with_span_success () =
  let result =
    Lwt_main.run
      (Ai_core.Telemetry.with_span ~__FILE__ ~__LINE__ ~data:(fun () -> []) "test.span" (fun _sp -> Lwt.return 42))
  in
  (check int) "returns value" 42 result

let test_with_span_exception () =
  let raised =
    try
      ignore
        (Lwt_main.run
           (Ai_core.Telemetry.with_span ~__FILE__ ~__LINE__
              ~data:(fun () -> [])
              "test.span"
              (fun _sp -> failwith "boom")));
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
      (Ai_core.Telemetry.maybe_span None "test.span" ~__FILE__ ~__LINE__
         ~data:(fun () -> [])
         (fun _sp ->
           called := true;
           Lwt.return 42))
  in
  (check bool) "function called" true !called

let test_maybe_span_disabled_explicit () =
  let t = Ai_core.Telemetry.create ~enabled:false () in
  let result =
    Lwt_main.run
      (Ai_core.Telemetry.maybe_span (Some t) "test.span" ~__FILE__ ~__LINE__
         ~data:(fun () -> [])
         (fun _sp -> Lwt.return 99))
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

(* ---- Traceparent Parsing ---- *)

let test_parse_valid_traceparent () =
  let tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" in
  match Ai_core.Telemetry.parse_traceparent tp with
  | Some tc ->
    (check string) "trace_id" "4bf92f3577b34da6a3ce929d0e0e4736" tc.trace_id;
    (check string) "parent_id" "00f067aa0ba902b7" tc.parent_id;
    (check bool) "sampled" true tc.sampled
  | None -> Alcotest.fail "expected Some"

let test_parse_traceparent_not_sampled () =
  let tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00" in
  match Ai_core.Telemetry.parse_traceparent tp with
  | Some tc -> (check bool) "not sampled" false tc.sampled
  | None -> Alcotest.fail "expected Some"

let test_parse_traceparent_wrong_length () =
  (check bool) "too short" true (Option.is_none (Ai_core.Telemetry.parse_traceparent "00-abc-def-01"));
  (check bool) "too long" true
    (Option.is_none
       (Ai_core.Telemetry.parse_traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra"))

let test_parse_traceparent_wrong_version () =
  (check bool) "version 01" true
    (Option.is_none (Ai_core.Telemetry.parse_traceparent "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"))

let test_parse_traceparent_bad_hex () =
  (check bool) "bad trace_id" true
    (Option.is_none (Ai_core.Telemetry.parse_traceparent "00-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ-00f067aa0ba902b7-01"));
  (check bool) "bad parent_id" true
    (Option.is_none (Ai_core.Telemetry.parse_traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-ZZZZZZZZZZZZZZZZ-01"))

let test_parse_traceparent_missing_dashes () =
  (check bool) "no dashes" true
    (Option.is_none (Ai_core.Telemetry.parse_traceparent "00X4bf92f3577b34da6a3ce929d0e0e4736X00f067aa0ba902b7X01"))

let test_parse_traceparent_all_zeros_invalid () =
  (* W3C spec: all-zero trace_id or parent_id is invalid *)
  (check bool) "zero trace_id" true
    (Option.is_none (Ai_core.Telemetry.parse_traceparent "00-00000000000000000000000000000000-00f067aa0ba902b7-01"));
  (check bool) "zero parent_id" true
    (Option.is_none (Ai_core.Telemetry.parse_traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"))

let test_parse_traceparent_uppercase_hex () =
  (* W3C spec says lowercase, but be lenient *)
  let tp = "00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01" in
  match Ai_core.Telemetry.parse_traceparent tp with
  | Some tc ->
    (check string) "trace_id lowercased" "4bf92f3577b34da6a3ce929d0e0e4736" tc.trace_id;
    (check string) "parent_id lowercased" "00f067aa0ba902b7" tc.parent_id
  | None -> Alcotest.fail "expected Some (uppercase accepted)"

(* ---- Traceparent on Telemetry.create ---- *)

let test_create_with_traceparent () =
  let tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" in
  let t = Ai_core.Telemetry.create ~enabled:true ~traceparent:tp () in
  match Ai_core.Telemetry.trace_context t with
  | Some tc ->
    (check string) "trace_id" "4bf92f3577b34da6a3ce929d0e0e4736" tc.trace_id;
    (check string) "parent_id" "00f067aa0ba902b7" tc.parent_id
  | None -> Alcotest.fail "expected trace_context"

let test_create_with_invalid_traceparent () =
  let t = Ai_core.Telemetry.create ~enabled:true ~traceparent:"garbage" () in
  (check bool) "invalid ignored" true (Option.is_none (Ai_core.Telemetry.trace_context t))

let test_create_without_traceparent () =
  let t = Ai_core.Telemetry.create ~enabled:true () in
  (check bool) "no trace_context" true (Option.is_none (Ai_core.Telemetry.trace_context t))

(* ---- Traceparent on Root Span ---- *)

let test_traceparent_root_span_attributes () =
  let collector, _get_span_names, get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_mock_model "Hello!" in
    let tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~traceparent:tp () in
    let _result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ()) in
    let root_data = get_span_data "ai.generateText" in
    (check string) "trace_id attr" "4bf92f3577b34da6a3ce929d0e0e4736"
      (match List.assoc_opt "ai.trace_context.trace_id" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (check string) "parent_id attr" "00f067aa0ba902b7"
      (match List.assoc_opt "ai.trace_context.parent_id" root_data with
      | Some (`String s) -> s
      | _ -> "");
    (check bool) "sampled attr" true
      (match List.assoc_opt "ai.trace_context.sampled" root_data with
      | Some (`Bool b) -> b
      | _ -> false))

let test_no_traceparent_no_trace_context_attrs () =
  let collector, _get_span_names, get_span_data = make_test_collector () in
  Trace_core.with_setup_collector collector (fun () ->
    let model = make_mock_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true () in
    let _result = Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ()) in
    let root_data = get_span_data "ai.generateText" in
    (check bool) "no trace_id" true (not (List.mem_assoc "ai.trace_context.trace_id" root_data));
    (check bool) "no parent_id" true (not (List.mem_assoc "ai.trace_context.parent_id" root_data)))

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
      ( "with_span",
        [ test_case "success" `Quick test_with_span_success; test_case "exception" `Quick test_with_span_exception ] );
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
      ( "parse_traceparent",
        [
          test_case "valid" `Quick test_parse_valid_traceparent;
          test_case "not sampled" `Quick test_parse_traceparent_not_sampled;
          test_case "wrong length" `Quick test_parse_traceparent_wrong_length;
          test_case "wrong version" `Quick test_parse_traceparent_wrong_version;
          test_case "bad hex" `Quick test_parse_traceparent_bad_hex;
          test_case "missing dashes" `Quick test_parse_traceparent_missing_dashes;
          test_case "all zeros invalid" `Quick test_parse_traceparent_all_zeros_invalid;
          test_case "uppercase hex" `Quick test_parse_traceparent_uppercase_hex;
        ] );
      ( "traceparent on create",
        [
          test_case "with valid traceparent" `Quick test_create_with_traceparent;
          test_case "with invalid traceparent" `Quick test_create_with_invalid_traceparent;
          test_case "without traceparent" `Quick test_create_without_traceparent;
        ] );
      ( "traceparent on root span",
        [
          test_case "attributes present" `Quick test_traceparent_root_span_attributes;
          test_case "no attributes when absent" `Quick test_no_traceparent_no_trace_context_attrs;
        ] );
    ]
