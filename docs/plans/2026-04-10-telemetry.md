# Telemetry / Observability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add OpenTelemetry-compatible span instrumentation and lifecycle callbacks to `generate_text`, `stream_text`, and `server_handler`, matching the upstream Vercel AI SDK's telemetry feature.

**Architecture:** The `trace` library (ocaml-trace 0.12) provides a collector-agnostic span API — libraries instrument with `Trace_core.enter_span`/`exit_span`, and the final application plugs in a backend (TEF, OpenTelemetry, Tracy, custom). We wrap this in an Lwt-aware `with_span_lwt` helper since `Trace_core.with_span` is synchronous and would close spans before Lwt promises resolve. A `Telemetry` module exposes settings (enable/disable, input/output recording, function ID, metadata), attribute selectivity (lazy evaluation gated on record_inputs/record_outputs), integration callbacks (on_start, on_step_finish, on_tool_call_start, on_tool_call_finish, on_finish), and a global integration registry. The span hierarchy matches upstream exactly: root (`ai.generateText`/`ai.streamText`) → step (`*.doGenerate`/`*.doStream`) → tool (`ai.toolCall`).

**Tech Stack:** `trace.core` (ocaml-trace 0.12, already in switch), `lwt`, `yojson`, existing `ai_core` / `ai_provider` modules.

---

## Upstream Reference

The upstream Vercel AI SDK telemetry implementation lives in:
- `node_modules/ai/src/telemetry/` — settings, attribute selection, span recording, integration registry
- `node_modules/ai/src/generate-text/generate-text.ts` — root + step spans for non-streaming
- `node_modules/ai/src/generate-text/stream-text.ts` — root + step spans for streaming
- `node_modules/ai/src/generate-text/execute-tool-call.ts` — tool call spans

### Span Hierarchy

```
ai.generateText                        (root — full operation including tool loop)
├── ai.generateText.doGenerate         (per-step LLM call, inside retry)
└── ai.toolCall                        (per tool execution)

ai.streamText                          (root — full streaming operation)
├── ai.streamText.doStream             (per-step streaming call, inside retry)
└── ai.toolCall                        (per tool execution)
```

### Attribute Keys (full upstream list)

**On every span (via `assembleOperationName` + `getBaseTelemetryAttributes`):**
- `operation.name` — `"{operationId} {functionId?}"`
- `resource.name` — functionId if present
- `ai.operationId` — the operation ID string
- `ai.telemetry.functionId` — user-provided function ID
- `ai.model.provider`, `ai.model.id`
- `ai.settings.maxOutputTokens`, `ai.settings.temperature`, etc.
- `ai.telemetry.metadata.{key}` — user custom metadata
- `ai.request.headers.{key}` — request headers

**On root span (generate/stream):**
- `ai.prompt` — INPUT: `JSON.stringify({system, prompt, messages})`

**On step span (doGenerate/doStream) — request attributes:**
- `ai.prompt.messages` — INPUT: stringified prompt messages
- `ai.prompt.tools` — INPUT: stringified tools array
- `ai.prompt.toolChoice` — INPUT: stringified tool choice
- `gen_ai.system` — provider name
- `gen_ai.request.model`, `gen_ai.request.frequency_penalty`, `gen_ai.request.max_tokens`,
  `gen_ai.request.presence_penalty`, `gen_ai.request.stop_sequences`,
  `gen_ai.request.temperature`, `gen_ai.request.top_k`, `gen_ai.request.top_p`

**On step span — response attributes (set after LLM call):**
- `ai.response.finishReason`, `ai.response.text` (OUTPUT), `ai.response.reasoning` (OUTPUT),
  `ai.response.toolCalls` (OUTPUT), `ai.response.id`, `ai.response.model`,
  `ai.response.timestamp`, `ai.response.providerMetadata`
- `ai.usage.inputTokens`, `ai.usage.outputTokens`, `ai.usage.totalTokens`
- `ai.usage.inputTokenDetails.cacheReadTokens`, `ai.usage.inputTokenDetails.cacheWriteTokens`,
  `ai.usage.outputTokenDetails.reasoningTokens`, etc.
- `gen_ai.response.finish_reasons`, `gen_ai.response.id`, `gen_ai.response.model`
- `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`

**On root span — final attributes (set after all steps):**
- Same response attributes as step span but with **aggregated** usage across all steps

**On tool call span:**
- `ai.toolCall.name`, `ai.toolCall.id`
- `ai.toolCall.args` — OUTPUT (these are LLM outputs, not user inputs)
- `ai.toolCall.result` — OUTPUT

**INPUT vs OUTPUT selectivity:**
- Attributes wrapped as `{ input: () => value }` are only recorded when `recordInputs !== false`
- Attributes wrapped as `{ output: () => value }` are only recorded when `recordOutputs !== false`
- Plain attributes are always recorded (when telemetry is enabled)
- When `isEnabled` is false, `selectTelemetryAttributes` returns `{}` — zero serialization cost

### Integration Callbacks

Upstream fires these in order: `onStart` → (loop: `onStepStart` → `onToolCallStart` → `onToolCallFinish` → `onStepFinish`) → `onFinish`. Both per-call and globally-registered integrations receive events.

---

## Task 1: Add `trace.core` dependency

**Files:**
- Modify: `lib/ai_core/dune`
- Modify: `dune-project`
- Modify: `test/ai_core/dune`
- Modify: `examples/dune`

**Step 1: Add trace.core to ai_core library**

In `lib/ai_core/dune`, add `trace.core` to the libraries list:

```
(libraries
  ai_provider
  lwt
  lwt.unix
  cohttp-lwt-unix
  yojson
  jsonschema
  melange-json-native
  re2
  uuseg.string
  trace.core)
```

**Step 2: Add trace to opam dependencies in dune-project**

In the `depends` section of the `ocaml-ai-sdk` package, add:

```
  (trace
   (>= 0.12))
```

**Step 3: Add trace.core to test and example dune files**

In `test/ai_core/dune`, add `trace.core` to libraries.
In `examples/dune`, add `trace.core` to libraries.

**Step 4: Verify the project builds**

Run: `dune build 2>&1 | head -20`
Expected: Clean build (no errors)

**Step 5: Commit**

```
feat(telemetry): add trace.core dependency
```

---

## Task 2: Create `Telemetry` module — types and settings

**Files:**
- Create: `lib/ai_core/telemetry.ml`
- Create: `lib/ai_core/telemetry.mli`

**Step 1: Write the test file**

Create `test/ai_core/test_telemetry.ml`:

```ocaml
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
  (check string) "operation.name" "ai.generateText" (List.assoc "operation.name" attrs);
  (check bool) "no resource.name" true (not (List.mem_assoc "resource.name" attrs));
  (check string) "ai.operationId" "ai.generateText" (List.assoc "ai.operationId" attrs);
  (check bool) "no ai.telemetry.functionId" true (not (List.mem_assoc "ai.telemetry.functionId" attrs))

let test_assemble_operation_name_with_function_id () =
  let t = Ai_core.Telemetry.create ~enabled:true ~function_id:"chat-endpoint" () in
  let attrs = Ai_core.Telemetry.assemble_operation_name ~operation_id:"ai.generateText" t in
  (check string) "operation.name" "ai.generateText chat-endpoint" (List.assoc "operation.name" attrs);
  (check string) "resource.name" "chat-endpoint" (List.assoc "resource.name" attrs);
  (check string) "ai.operationId" "ai.generateText" (List.assoc "ai.operationId" attrs);
  (check string) "ai.telemetry.functionId" "chat-endpoint" (List.assoc "ai.telemetry.functionId" attrs)

(* ---- Base Telemetry Attributes ---- *)

let test_base_attributes () =
  let t =
    Ai_core.Telemetry.create ~enabled:true ~metadata:[ "env", `String "prod"; "version", `Int 3 ]
      ()
  in
  let attrs =
    Ai_core.Telemetry.base_attributes ~provider:"anthropic" ~model_id:"claude-sonnet-4-6" ~settings_attrs:[]
      ~headers:[ "x-custom", "val" ] t
  in
  (check string) "provider" "anthropic"
    (match List.assoc "ai.model.provider" attrs with `String s -> s | _ -> "");
  (check string) "model" "claude-sonnet-4-6"
    (match List.assoc "ai.model.id" attrs with `String s -> s | _ -> "");
  (check string) "metadata.env" "prod"
    (match List.assoc "ai.telemetry.metadata.env" attrs with `String s -> s | _ -> "");
  (check int) "metadata.version" 3
    (match List.assoc "ai.telemetry.metadata.version" attrs with `Int n -> n | _ -> 0);
  (check string) "header" "val"
    (match List.assoc "ai.request.headers.x-custom" attrs with `String s -> s | _ -> "")

let test_base_attributes_with_settings () =
  let t = Ai_core.Telemetry.create ~enabled:true () in
  let settings_attrs =
    [
      "ai.settings.maxOutputTokens", `Int 1000;
      "ai.settings.temperature", `Float 0.7;
    ]
  in
  let attrs =
    Ai_core.Telemetry.base_attributes ~provider:"anthropic" ~model_id:"claude-sonnet-4-6"
      ~settings_attrs ~headers:[] t
  in
  (check int) "maxOutputTokens" 1000
    (match List.assoc "ai.settings.maxOutputTokens" attrs with `Int n -> n | _ -> 0);
  (check (float 0.01)) "temperature" 0.7
    (match List.assoc "ai.settings.temperature" attrs with `Float f -> f | _ -> 0.0)

(* ---- Lwt Span Helper ---- *)

let test_with_span_lwt_success () =
  (* No collector installed — span is dummy, but the function should execute *)
  let result =
    Lwt_main.run
      (Ai_core.Telemetry.with_span_lwt ~data:(fun () -> []) "test.span" (fun _sp -> Lwt.return 42))
  in
  (check int) "returns value" 42 result

let test_with_span_lwt_exception () =
  (* Should re-raise exceptions after exiting the span *)
  let raised =
    try
      ignore
        (Lwt_main.run
           (Ai_core.Telemetry.with_span_lwt ~data:(fun () -> []) "test.span" (fun _sp -> failwith "boom")));
      false
    with Failure msg ->
      String.equal msg "boom"
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
    { model = { provider = "mock"; model_id = "mock-v1" }; messages = []; tools = []; function_id = None; metadata = [] }
  in
  Lwt_main.run (Ai_core.Telemetry.notify_on_start t event);
  (check int) "both called" 2 (List.length !call_log);
  (* Should be called in order *)
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
    { model = { provider = "mock"; model_id = "mock-v1" }; messages = []; tools = []; function_id = None; metadata = [] }
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
    { model = { provider = "mock"; model_id = "mock-v1" }; messages = []; tools = []; function_id = None; metadata = [] }
  in
  Lwt_main.run (Ai_core.Telemetry.notify_on_start t event);
  (check bool) "global called" true !called;
  (* Clean up: reset global integrations *)
  Ai_core.Telemetry.clear_global_integrations ()

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
        ] );
    ]
```

**Step 2: Register the test**

Add `test_telemetry` to `test/ai_core/dune`:
- Add to the `names` list
- Ensure `trace.core` is in libraries (from Task 1)

**Step 3: Run the tests to verify they fail**

Run: `dune test test/ai_core/test_telemetry.exe 2>&1 | head -10`
Expected: Compilation error — `Ai_core.Telemetry` module not found

**Step 4: Write `telemetry.mli`**

Create `lib/ai_core/telemetry.mli`:

```ocaml
(** Telemetry configuration for AI SDK operations.

    Mirrors the upstream AI SDK's TelemetrySettings. When [enabled] is
    [false] (the default), all instrumentation is skipped with zero
    overhead — [Trace_core] returns dummy spans and never serializes
    attribute data.

    {2 Quick start}

    {[
      (* 1. Install a trace collector in your application entrypoint *)
      let () = Trace_core.setup_collector (my_otel_collector ())

      (* 2. Pass telemetry settings to generate_text / stream_text *)
      let telemetry =
        Telemetry.create ~enabled:true ~function_id:"chat-completion"
          ~metadata:[ "user_id", `String "u-123" ]
          ()

      let%lwt result = Generate_text.generate_text ~model ~messages ~telemetry ()
    ]}

    {2 Span hierarchy}

    {v
    ai.generateText                     (root — full operation)
    ├── ai.generateText.doGenerate      (per-step LLM call)
    └── ai.toolCall                     (per tool execution)

    ai.streamText                       (root — full streaming operation)
    ├── ai.streamText.doStream          (per-step streaming call)
    └── ai.toolCall                     (per tool execution)
    v}

    {2 Attribute selectivity}

    Attributes are classified as [Input] (prompts, tools),
    [Output] (responses, tool results), or [Always] (model info, usage).
    [Input] attributes are only recorded when [record_inputs] is [true],
    [Output] when [record_outputs] is [true]. When [enabled] is [false],
    no attributes are evaluated at all (zero serialization cost). *)

(** {1 Settings} *)

type t

val create :
  ?enabled:bool ->
  ?record_inputs:bool ->
  ?record_outputs:bool ->
  ?function_id:string ->
  ?metadata:(string * Trace_core.user_data) list ->
  ?integrations:integration list ->
  unit ->
  t

val enabled : t -> bool
val record_inputs : t -> bool
val record_outputs : t -> bool
val function_id : t -> string option
val metadata : t -> (string * Trace_core.user_data) list
val integrations : t -> integration list

(** {1 Attribute Selection} *)

(** Attribute that may be conditionally recorded.
    - [Always v]: recorded whenever telemetry is enabled
    - [Input f]: recorded only when [record_inputs] is [true]; [f] evaluated lazily
    - [Output f]: recorded only when [record_outputs] is [true]; [f] evaluated lazily *)
type attr =
  | Always of Trace_core.user_data
  | Input of (unit -> Trace_core.user_data)
  | Output of (unit -> Trace_core.user_data)

(** Select attributes respecting telemetry settings.
    Returns [[]] immediately when [enabled] is [false]. *)
val select_attributes : t -> (string * attr) list -> (string * Trace_core.user_data) list

(** {1 Operation Name Assembly}

    Builds the standard operation name attributes matching upstream:
    [operation.name], [resource.name], [ai.operationId],
    [ai.telemetry.functionId]. *)
val assemble_operation_name :
  operation_id:string -> t -> (string * Trace_core.user_data) list

(** {1 Base Telemetry Attributes}

    Model info, call settings, user metadata, and request headers.
    Used on every span. *)
val base_attributes :
  provider:string ->
  model_id:string ->
  settings_attrs:(string * Trace_core.user_data) list ->
  headers:(string * string) list ->
  t ->
  (string * Trace_core.user_data) list

(** Build settings attributes from call options.
    Only includes non-None values. *)
val settings_attributes :
  ?max_output_tokens:int ->
  ?temperature:float ->
  ?top_p:float ->
  ?top_k:int ->
  ?stop_sequences:string list ->
  ?seed:int ->
  ?frequency_penalty:float ->
  ?presence_penalty:float ->
  ?max_retries:int ->
  unit ->
  (string * Trace_core.user_data) list

(** {1 Lwt Span Helpers} *)

(** [with_span_lwt name ~data f] opens a span, runs [f span], and closes
    the span when the Lwt promise resolves or fails. On failure, the
    exception message is recorded on the span via [add_data_to_span]
    before re-raising.

    Uses [Trace_core.enter_span] / [exit_span] (not [with_span]) so
    the span stays open across Lwt yield points.

    When no [Trace_core] collector is installed, the span is a dummy
    and the overhead is a single allocation + [Lwt.finalize]. *)
val with_span_lwt :
  ?parent:Trace_core.span ->
  data:(unit -> (string * Trace_core.user_data) list) ->
  string ->
  (Trace_core.span -> 'a Lwt.t) ->
  'a Lwt.t

(** {1 Integration Callbacks} *)

(** Model info for callback events. *)
type model_info = {
  provider : string;
  model_id : string;
}

(** Lifecycle callbacks for telemetry events.

    All callbacks are optional — implement only the ones you need.
    Errors in callbacks are caught and ignored (they must not break
    the generation pipeline). Callbacks are called in order:
    per-call integrations first, then global integrations. *)
and integration = {
  on_start : (on_start_event -> unit Lwt.t) option;
  on_step_finish : (on_step_finish_event -> unit Lwt.t) option;
  on_tool_call_start : (on_tool_call_start_event -> unit Lwt.t) option;
  on_tool_call_finish : (on_tool_call_finish_event -> unit Lwt.t) option;
  on_finish : (on_finish_event -> unit Lwt.t) option;
}

and on_start_event = {
  model : model_info;
  messages : Ai_provider.Prompt.message list;
  tools : (string * Core_tool.t) list;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

and on_step_finish_event = {
  step_number : int;
  step : Generate_text_result.step;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

and on_tool_call_start_event = {
  step_number : int;
  model : model_info;
  tool_name : string;
  tool_call_id : string;
  args : Yojson.Basic.t;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

and on_tool_call_finish_event = {
  step_number : int;
  model : model_info;
  tool_name : string;
  tool_call_id : string;
  args : Yojson.Basic.t;
  result : tool_call_outcome;
  duration_ms : float;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

and tool_call_outcome =
  | Success of Yojson.Basic.t
  | Error of string

and on_finish_event = {
  steps : Generate_text_result.step list;
  total_usage : Ai_provider.Usage.t;
  finish_reason : Ai_provider.Finish_reason.t;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

(** An empty integration with no callbacks. Useful as a starting
    point for building partial integrations:

    {[
      { Telemetry.no_integration with
        on_finish = Some (fun event -> ...);
      }
    ]} *)
val no_integration : integration

(** Notify all integrations (per-call + global) of an event.
    Errors are caught and logged to stderr. *)

val notify_on_start : t -> on_start_event -> unit Lwt.t
val notify_on_step_finish : t -> on_step_finish_event -> unit Lwt.t
val notify_on_tool_call_start : t -> on_tool_call_start_event -> unit Lwt.t
val notify_on_tool_call_finish : t -> on_tool_call_finish_event -> unit Lwt.t
val notify_on_finish : t -> on_finish_event -> unit Lwt.t

(** {1 Global Integration Registry} *)

(** Register an integration that receives events from all AI SDK
    operations. Useful for application-wide logging or metrics. *)
val register_global_integration : integration -> unit

(** Remove all global integrations. Primarily for testing. *)
val clear_global_integrations : unit -> unit
```

**Step 5: Write `telemetry.ml`**

Create `lib/ai_core/telemetry.ml`:

```ocaml
(* ---- Integration types ---- *)

type model_info = {
  provider : string;
  model_id : string;
}

type integration = {
  on_start : (on_start_event -> unit Lwt.t) option;
  on_step_finish : (on_step_finish_event -> unit Lwt.t) option;
  on_tool_call_start : (on_tool_call_start_event -> unit Lwt.t) option;
  on_tool_call_finish : (on_tool_call_finish_event -> unit Lwt.t) option;
  on_finish : (on_finish_event -> unit Lwt.t) option;
}

and on_start_event = {
  model : model_info;
  messages : Ai_provider.Prompt.message list;
  tools : (string * Core_tool.t) list;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

and on_step_finish_event = {
  step_number : int;
  step : Generate_text_result.step;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

and on_tool_call_start_event = {
  step_number : int;
  model : model_info;
  tool_name : string;
  tool_call_id : string;
  args : Yojson.Basic.t;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

and on_tool_call_finish_event = {
  step_number : int;
  model : model_info;
  tool_name : string;
  tool_call_id : string;
  args : Yojson.Basic.t;
  result : tool_call_outcome;
  duration_ms : float;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

and tool_call_outcome =
  | Success of Yojson.Basic.t
  | Error of string

and on_finish_event = {
  steps : Generate_text_result.step list;
  total_usage : Ai_provider.Usage.t;
  finish_reason : Ai_provider.Finish_reason.t;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
}

let no_integration =
  { on_start = None; on_step_finish = None; on_tool_call_start = None; on_tool_call_finish = None; on_finish = None }

(* ---- Settings ---- *)

type t = {
  enabled : bool;
  record_inputs : bool;
  record_outputs : bool;
  function_id : string option;
  metadata : (string * Trace_core.user_data) list;
  integrations : integration list;
}

let create ?(enabled = false) ?(record_inputs = true) ?(record_outputs = true) ?function_id ?(metadata = [])
  ?(integrations = []) () =
  { enabled; record_inputs; record_outputs; function_id; metadata; integrations }

let enabled t = t.enabled
let record_inputs t = t.record_inputs
let record_outputs t = t.record_outputs
let function_id t = t.function_id
let metadata t = t.metadata
let integrations t = t.integrations

(* ---- Attribute Selection ---- *)

type attr =
  | Always of Trace_core.user_data
  | Input of (unit -> Trace_core.user_data)
  | Output of (unit -> Trace_core.user_data)

let select_attributes t attrs =
  match t.enabled with
  | false -> []
  | true ->
    List.filter_map
      (fun (key, attr) ->
        match attr with
        | Always v -> Some (key, v)
        | Input f ->
          (match t.record_inputs with
          | true -> Some (key, f ())
          | false -> None)
        | Output f ->
          (match t.record_outputs with
          | true -> Some (key, f ())
          | false -> None))
      attrs

(* ---- Operation Name Assembly ---- *)

let assemble_operation_name ~operation_id t =
  let base =
    [
      ( "operation.name",
        `String
          (match t.function_id with
          | Some fid -> Printf.sprintf "%s %s" operation_id fid
          | None -> operation_id) );
      "ai.operationId", `String operation_id;
    ]
  in
  match t.function_id with
  | Some fid -> ("resource.name", `String fid) :: ("ai.telemetry.functionId", `String fid) :: base
  | None -> base

(* ---- Base Telemetry Attributes ---- *)

let base_attributes ~provider ~model_id ~settings_attrs ~headers t =
  let model_attrs = [ "ai.model.provider", `String provider; "ai.model.id", `String model_id ] in
  let metadata_attrs =
    List.map (fun (k, v) -> Printf.sprintf "ai.telemetry.metadata.%s" k, v) t.metadata
  in
  let header_attrs =
    List.map (fun (k, v) -> Printf.sprintf "ai.request.headers.%s" k, (`String v : Trace_core.user_data)) headers
  in
  model_attrs @ settings_attrs @ metadata_attrs @ header_attrs

let settings_attributes ?max_output_tokens ?temperature ?top_p ?top_k ?stop_sequences ?seed ?frequency_penalty
  ?presence_penalty ?max_retries () =
  let add key f opt acc =
    match opt with
    | Some v -> (key, f v) :: acc
    | None -> acc
  in
  []
  |> add "ai.settings.maxRetries" (fun v -> `Int v) max_retries
  |> add "ai.settings.presencePenalty" (fun v -> `Float v) presence_penalty
  |> add "ai.settings.frequencyPenalty" (fun v -> `Float v) frequency_penalty
  |> add "ai.settings.seed" (fun v -> `Int v) seed
  |> add "ai.settings.topK" (fun v -> `Int v) top_k
  |> add "ai.settings.topP" (fun v -> `Float v) top_p
  |> add "ai.settings.temperature" (fun v -> `Float v) temperature
  |> add "ai.settings.maxOutputTokens" (fun v -> `Int v) max_output_tokens
  |> (fun acc ->
    match stop_sequences with
    | Some seqs when seqs <> [] ->
      ("ai.settings.stopSequences", `String (String.concat "," seqs)) :: acc
    | _ -> acc)

(* ---- Lwt Span Helpers ---- *)

let with_span_lwt ?parent ~data name f =
  let sp =
    Trace_core.enter_span ~__FILE__ ~__LINE__ ~flavor:`Async
      ?parent:(Option.map Option.some parent) ~data name
  in
  Lwt.catch
    (fun () ->
      let%lwt result = f sp in
      Trace_core.exit_span sp;
      Lwt.return result)
    (fun exn ->
      Trace_core.add_data_to_span sp
        [ "error", `Bool true; "error.message", `String (Printexc.to_string exn) ];
      Trace_core.exit_span sp;
      raise exn)

(* ---- Global Integration Registry ---- *)

let global_integrations : integration list ref = ref []

let register_global_integration integration =
  global_integrations := !global_integrations @ [ integration ]

let clear_global_integrations () = global_integrations := []

(* ---- Integration Notification ---- *)

let all_integrations t = t.integrations @ !global_integrations

let notify_all t extract_callback event =
  match t.enabled with
  | false -> Lwt.return_unit
  | true ->
    let integrations = all_integrations t in
    Lwt_list.iter_s
      (fun integration ->
        match extract_callback integration with
        | None -> Lwt.return_unit
        | Some callback ->
          Lwt.catch
            (fun () -> callback event)
            (fun exn ->
              Printf.eprintf "[ai_core] telemetry integration error: %s\n%!" (Printexc.to_string exn);
              Lwt.return_unit))
      integrations

let notify_on_start t event = notify_all t (fun i -> i.on_start) event
let notify_on_step_finish t event = notify_all t (fun i -> i.on_step_finish) event
let notify_on_tool_call_start t event = notify_all t (fun i -> i.on_tool_call_start) event
let notify_on_tool_call_finish t event = notify_all t (fun i -> i.on_tool_call_finish) event
let notify_on_finish t event = notify_all t (fun i -> i.on_finish) event
```

**Step 6: Run the tests**

Run: `dune test test/ai_core/test_telemetry.exe 2>&1`
Expected: All tests pass

**Step 7: Commit**

```
feat(telemetry): add Telemetry module with settings, attributes, spans, and integrations
```

---

## Task 3: Instrument `generate_text`

**Files:**
- Modify: `lib/ai_core/generate_text.ml`
- Modify: `lib/ai_core/generate_text.mli`

**Step 1: Write the tests**

Add to `test/ai_core/test_generate_text.ml` (new tests at end, before `let () = run ...`):

```ocaml
(* ---- Telemetry tests ---- *)

(** Minimal trace collector that records span names and data *)
let make_test_collector () =
  let spans = ref [] in
  let span_data : (int, (string * Trace_core.user_data) list ref) Hashtbl.t = Hashtbl.create 16 in
  let next_id = ref 0 in
  type Trace_core.span += Test_span of int
  let callbacks : unit Trace_core.Collector.Callbacks.t =
    Trace_core.Collector.Callbacks.make
      ~enter_span:(fun () ~__FUNCTION__:_ ~__FILE__:_ ~__LINE__:_ ~level:_ ~parent:_ ~params:_ ~data name ->
        let id = !next_id in
        incr next_id;
        spans := (id, name) :: !spans;
        let data_ref = ref data in
        Hashtbl.replace span_data id data_ref;
        Test_span id)
      ~exit_span:(fun () _sp -> ())
      ~add_data_to_span:(fun () sp data ->
        match sp with
        | Test_span id ->
          (match Hashtbl.find_opt span_data id with
          | Some data_ref -> data_ref := !data_ref @ data
          | None -> ())
        | _ -> ())
      ~message:(fun () ~level:_ ~span:_ ~params:_ ~data:_ _msg -> ())
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
  (collector, get_span_names, get_span_data)

let test_telemetry_spans () =
  let (collector, get_span_names, _get_span_data) = make_test_collector () in
  Trace_core.setup_collector collector;
  Fun.protect ~finally:Trace_core.shutdown (fun () ->
    let model = make_text_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~function_id:"test-fn" () in
    let _result =
      Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ())
    in
    let names = get_span_names () in
    (* Should have root span + one step span *)
    (check bool) "has root" true (List.mem "ai.generateText" names);
    (check bool) "has step" true (List.mem "ai.generateText.doGenerate" names))

let test_telemetry_tool_spans () =
  let (collector, get_span_names, _get_span_data) = make_test_collector () in
  Trace_core.setup_collector collector;
  Fun.protect ~finally:Trace_core.shutdown (fun () ->
    let model = make_tool_model () in
    let telemetry = Ai_core.Telemetry.create ~enabled:true () in
    let _result =
      Lwt_main.run
        (Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
           ~tools:[ "search", search_tool ] ~max_steps:3 ~telemetry ())
    in
    let names = get_span_names () in
    (check bool) "has root" true (List.mem "ai.generateText" names);
    (check bool) "has tool call" true (List.mem "ai.toolCall" names);
    (* 2 step spans: tool call step + final answer step *)
    let step_count = List.length (List.filter (String.equal "ai.generateText.doGenerate") names) in
    (check int) "2 step spans" 2 step_count)

let test_telemetry_root_attributes () =
  let (collector, _get_span_names, get_span_data) = make_test_collector () in
  Trace_core.setup_collector collector;
  Fun.protect ~finally:Trace_core.shutdown (fun () ->
    let model = make_text_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:true ~function_id:"my-fn" () in
    let _result =
      Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ())
    in
    let data = get_span_data "ai.generateText" in
    (check string) "operation.name"
      "ai.generateText my-fn"
      (match List.assoc_opt "operation.name" data with Some (`String s) -> s | _ -> "");
    (check string) "ai.model.provider"
      "mock"
      (match List.assoc_opt "ai.model.provider" data with Some (`String s) -> s | _ -> "");
    (check string) "ai.model.id"
      "mock-v1"
      (match List.assoc_opt "ai.model.id" data with Some (`String s) -> s | _ -> ""))

let test_telemetry_disabled_no_spans () =
  let (collector, get_span_names, _get_span_data) = make_test_collector () in
  Trace_core.setup_collector collector;
  Fun.protect ~finally:Trace_core.shutdown (fun () ->
    let model = make_text_model "Hello!" in
    let telemetry = Ai_core.Telemetry.create ~enabled:false () in
    let _result =
      Lwt_main.run (Ai_core.Generate_text.generate_text ~model ~prompt:"Hi" ~telemetry ())
    in
    let names = get_span_names () in
    (check int) "no spans when disabled" 0 (List.length names))

let test_telemetry_integration_callbacks () =
  let events = ref [] in
  let integration : Ai_core.Telemetry.integration =
    {
      on_start = Some (fun e -> events := Printf.sprintf "start:%s" e.model.provider :: !events; Lwt.return_unit);
      on_step_finish = Some (fun e -> events := Printf.sprintf "step:%d" e.step_number :: !events; Lwt.return_unit);
      on_tool_call_start = Some (fun e -> events := Printf.sprintf "tool_start:%s" e.tool_name :: !events; Lwt.return_unit);
      on_tool_call_finish = Some (fun e -> events := Printf.sprintf "tool_finish:%s" e.tool_name :: !events; Lwt.return_unit);
      on_finish = Some (fun e -> events := Printf.sprintf "finish:%d_steps" (List.length e.steps) :: !events; Lwt.return_unit);
    }
  in
  let model = make_tool_model () in
  let telemetry = Ai_core.Telemetry.create ~enabled:true ~integrations:[ integration ] () in
  let _result =
    Lwt_main.run
      (Ai_core.Generate_text.generate_text ~model ~prompt:"Search"
         ~tools:[ "search", search_tool ] ~max_steps:3 ~telemetry ())
  in
  let evts = List.rev !events in
  (check bool) "has start" true (List.exists (fun s -> String.starts_with ~prefix:"start:" s) evts);
  (check bool) "has tool_start" true (List.exists (fun s -> String.starts_with ~prefix:"tool_start:" s) evts);
  (check bool) "has tool_finish" true (List.exists (fun s -> String.starts_with ~prefix:"tool_finish:" s) evts);
  (check bool) "has step" true (List.exists (fun s -> String.starts_with ~prefix:"step:" s) evts);
  (check bool) "has finish" true (List.exists (fun s -> String.starts_with ~prefix:"finish:" s) evts)
```

Add these to the test runner:

```ocaml
      ( "telemetry",
        [
          test_case "span hierarchy" `Quick test_telemetry_spans;
          test_case "tool call spans" `Quick test_telemetry_tool_spans;
          test_case "root attributes" `Quick test_telemetry_root_attributes;
          test_case "disabled no spans" `Quick test_telemetry_disabled_no_spans;
          test_case "integration callbacks" `Quick test_telemetry_integration_callbacks;
        ] );
```

**Step 2: Run tests to verify they fail**

Run: `dune test test/ai_core/test_generate_text.exe 2>&1 | head -10`
Expected: Compilation error — `generate_text` doesn't accept `~telemetry`

**Step 3: Add `?telemetry` parameter to `generate_text.mli`**

Add `?telemetry:Telemetry.t ->` to the signature, after `?on_step_finish`.

**Step 4: Instrument `generate_text.ml`**

The instrumentation follows this pattern for the function:

1. If `telemetry` is `None` or `enabled = false`, run existing code unchanged.
2. Otherwise, wrap the entire function in a root span `"ai.generateText"`.
3. Wrap each LLM call (inside `Retry.with_retries`) in a step span `"ai.generateText.doGenerate"`.
4. Wrap each tool execution in an `"ai.toolCall"` span.
5. Fire integration callbacks at the appropriate lifecycle points.

The key changes to `generate_text.ml`:

- Add `?telemetry` parameter.
- Compute base attributes (operation name + model + settings + metadata + headers) once at the top.
- Root span wraps the entire step loop.
- Step span wraps `Retry.with_retries (fun () -> Language_model.generate ...)`. After the call completes, add response attributes to the step span.
- Tool call span wraps `Core_tool.execute_tool`. Before: fire `notify_on_tool_call_start`. After: fire `notify_on_tool_call_finish`.
- After each step: fire `notify_on_step_finish` (the existing `on_step_finish` callback is separate from telemetry).
- After all steps: add final aggregated usage attributes to root span, fire `notify_on_finish`.

The `None` telemetry path should add zero overhead — no span creation, no attribute computation. Use a helper:

```ocaml
let maybe_span telemetry name ~data f =
  match telemetry with
  | Some t when Telemetry.enabled t -> Telemetry.with_span_lwt ~data name f
  | _ -> f Trace_core.Collector.dummy_span
```

For response attributes on the step span, use `Trace_core.add_data_to_span` after the LLM call returns. Build attributes with `Telemetry.select_attributes` to respect `record_inputs` / `record_outputs`.

For tool call spans, the timing pattern is:

```ocaml
let t0 = Unix.gettimeofday () in
(* ... execute tool ... *)
let duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
```

**Step 5: Run the tests**

Run: `dune test test/ai_core/test_generate_text.exe 2>&1`
Expected: All tests pass (existing + new)

**Step 6: Commit**

```
feat(telemetry): instrument generate_text with spans and integration callbacks
```

---

## Task 4: Instrument `stream_text`

**Files:**
- Modify: `lib/ai_core/stream_text.ml`
- Modify: `lib/ai_core/stream_text.mli`

**Step 1: Write the tests**

Add telemetry tests to `test/ai_core/test_stream_text.ml`, following the same pattern as generate_text tests but for the streaming path. Key differences:

- Stream root span (`"ai.streamText"`) is manually ended when the stream completes (not auto-ended).
- Step span (`"ai.streamText.doStream"`) is ended after the step's stream is consumed.
- Tool spans and integration callbacks work identically.

Test cases needed:
- `test_stream_telemetry_spans`: basic streaming creates root + step span
- `test_stream_telemetry_tool_spans`: streaming with tools creates tool call spans
- `test_stream_telemetry_disabled`: no spans when disabled
- `test_stream_telemetry_integration_callbacks`: lifecycle callbacks fire

Use the same `make_test_collector` helper (extract it to a shared test utility or duplicate it).

**Step 2: Run tests to verify they fail**

**Step 3: Add `?telemetry` parameter to `stream_text.mli`**

Add `?telemetry:Telemetry.t ->` after `?on_finish`.

**Step 4: Instrument `stream_text.ml`**

Same pattern as `generate_text`, with these streaming-specific considerations:

- The root span must be opened before the `Lwt.async` block and closed inside it when the stream finishes (in `finish_stream`) or on error.
- Use `Trace_core.enter_span` at the top, and `Trace_core.exit_span` in `finish_stream` and the `with exn` handler.
- Step spans similarly: enter before `Language_model.stream`, exit after `consume_provider_stream` returns.
- Final attributes are added to root span in `finish_stream`.

**Step 5: Run all tests**

Run: `dune test 2>&1 | tail -20`
Expected: All tests pass

**Step 6: Commit**

```
feat(telemetry): instrument stream_text with spans and integration callbacks
```

---

## Task 5: Thread `?telemetry` through `server_handler`

**Files:**
- Modify: `lib/ai_core/server_handler.ml`
- Modify: `lib/ai_core/server_handler.mli`

**Step 1: Add `?telemetry:Telemetry.t` to `handle_chat` in `.mli`**

Add after `?transform`:

```ocaml
  ?telemetry:Telemetry.t ->
```

**Step 2: Thread the parameter in `server_handler.ml`**

In `handle_chat`, add `?telemetry` to the parameter list and pass it through to `Stream_text.stream_text`:

```ocaml
let result =
  Stream_text.stream_text ~model ~messages ?tools ?max_steps ?max_retries
    ?stop_when ?output ?provider_options ?transform ?telemetry
    ~pending_tool_approvals ()
in
```

**Step 3: Verify build**

Run: `dune build 2>&1 | head -10`
Expected: Clean build

**Step 4: Commit**

```
feat(telemetry): thread telemetry parameter through server_handler
```

---

## Task 6: Add telemetry logging example

**Files:**
- Create: `examples/telemetry_logging.ml`
- Modify: `examples/dune`

**Step 1: Write the example**

Create `examples/telemetry_logging.ml`:

```ocaml
(** Telemetry logging example.

    Demonstrates two ways to observe AI SDK operations:

    1. **Integration callbacks** — structured lifecycle events
       (on_start, on_tool_call_start, on_tool_call_finish,
       on_step_finish, on_finish) for application-level logging,
       metrics, and third-party integrations (Langfuse, Helicone, etc.).

    2. **Trace spans** — OpenTelemetry-compatible spans via the
       [trace] library for distributed tracing backends (Jaeger,
       Zipkin, Datadog, etc.). Install any [trace]-compatible collector;
       here we use [trace-tef] to write Chrome Trace Format JSON
       viewable in https://ui.perfetto.dev .

    Set ANTHROPIC_API_KEY environment variable before running.

    Usage: dune exec examples/telemetry_logging.exe *)

(* ---- 1. Integration Callbacks ---- *)

(** A simple logging integration that prints lifecycle events.
    In a real app, you'd send these to your observability platform. *)
let logging_integration : Ai_core.Telemetry.integration =
  {
    on_start =
      Some
        (fun event ->
          Printf.printf "[telemetry] start: model=%s/%s messages=%d tools=%d\n%!" event.model.provider
            event.model.model_id
            (List.length event.messages)
            (List.length event.tools);
          Lwt.return_unit);
    on_step_finish =
      Some
        (fun event ->
          Printf.printf "[telemetry] step %d finished: %s (%d in / %d out tokens)\n%!" event.step_number
            (Ai_provider.Finish_reason.to_string event.step.finish_reason)
            event.step.usage.input_tokens event.step.usage.output_tokens;
          Lwt.return_unit);
    on_tool_call_start =
      Some
        (fun event ->
          Printf.printf "[telemetry] tool call start: %s (id=%s)\n%!" event.tool_name event.tool_call_id;
          Lwt.return_unit);
    on_tool_call_finish =
      Some
        (fun event ->
          let status =
            match event.result with
            | Ai_core.Telemetry.Success _ -> "success"
            | Ai_core.Telemetry.Error msg -> Printf.sprintf "error: %s" msg
          in
          Printf.printf "[telemetry] tool call finish: %s — %s (%.0fms)\n%!" event.tool_name status event.duration_ms;
          Lwt.return_unit);
    on_finish =
      Some
        (fun event ->
          Printf.printf "[telemetry] finished: %d steps, %s, %d total input / %d total output tokens\n%!"
            (List.length event.steps)
            (Ai_provider.Finish_reason.to_string event.finish_reason)
            event.total_usage.input_tokens event.total_usage.output_tokens;
          Lwt.return_unit);
  }

(* ---- Tool definition ---- *)

let weather_tool =
  Ai_core.Core_tool.create ~description:"Get current weather for a city"
    ~parameters:
      (`Assoc
        [
          "type", `String "object";
          ( "properties",
            `Assoc
              [
                ( "city",
                  `Assoc [ "type", `String "string"; "description", `String "City name, e.g. 'Paris'" ] );
              ] );
          "required", `List [ `String "city" ];
        ])
    ~execute:(fun args ->
      let city =
        match args with
        | `Assoc pairs ->
          (match List.assoc_opt "city" pairs with
          | Some (`String c) -> c
          | _ -> "unknown")
        | _ -> "unknown"
      in
      Printf.printf "  [tool] Fetching weather for %s...\n%!" city;
      Lwt.return (`Assoc [ "city", `String city; "temp_c", `Int 22; "condition", `String "Sunny" ]))
    ()

(* ---- Main ---- *)

let () =
  Lwt_main.run
  begin
    (* ---- 2. Trace Spans ----
       Install a trace collector to capture spans. Here we just log to
       stderr for demonstration. In production, use trace-tef for
       Chrome Trace Format, or opentelemetry.trace for OTLP export.

       Example with trace-tef (add trace-tef to deps):
         Trace_tef.setup ~out:(`File "ai-trace.json") ();
         (* ... run operations ... *)
         Trace_core.shutdown ()
         (* Open ai-trace.json in https://ui.perfetto.dev *)
    *)

    let model =
      Ai_provider_anthropic.model
        Ai_provider_anthropic.Model_catalog.(to_model_id Claude_haiku_4_5)
    in

    (* Create telemetry settings with our logging integration *)
    let telemetry =
      Ai_core.Telemetry.create ~enabled:true ~function_id:"weather-chat"
        ~metadata:[ "example", `String "telemetry_logging"; "user_id", `String "demo-user" ]
        ~integrations:[ logging_integration ]
        ()
    in

    Printf.printf "=== generate_text with telemetry ===\n\n%!";

    let%lwt result =
      Ai_core.Generate_text.generate_text ~model
        ~system:"You are a helpful weather assistant. Use the weather tool to answer questions."
        ~prompt:"What's the weather like in Paris and Tokyo?"
        ~tools:[ "get_weather", weather_tool ]
        ~max_steps:5 ~telemetry ()
    in

    Printf.printf "\n=== Response ===\n%s\n\n%!" result.text;
    Printf.printf "Total: %d input / %d output tokens, %d steps\n%!" result.usage.input_tokens
      result.usage.output_tokens (List.length result.steps);

    Lwt.return_unit
  end
```

**Step 2: Add to examples/dune**

Add `telemetry_logging` to the `names` list. Add `trace.core` to libraries if not already done in Task 1.

**Step 3: Verify it compiles**

Run: `dune build examples/telemetry_logging.exe 2>&1`
Expected: Clean build

**Step 4: Commit**

```
feat(telemetry): add telemetry_logging example with integration callbacks
```

---

## Task 7: Update roadmap and changelog

**Files:**
- Modify: `docs/plans/2026-03-26-v2-roadmap.md`
- Modify: `CHANGES.md` (if it exists, or `CHANGELOG.md`)

**Step 1: Mark telemetry item as Done in the roadmap**

Move item #7 to the Completed section with a summary of what was implemented.

**Step 2: Add changelog entry**

Add an entry under Unreleased:

```
### Added
- Telemetry / observability: OpenTelemetry-compatible span instrumentation
  for `generate_text`, `stream_text`, and `server_handler` via the `trace`
  library. Configurable `Telemetry.t` settings control enable/disable,
  input/output recording privacy, function ID, custom metadata, and
  lifecycle integration callbacks (on_start, on_step_finish,
  on_tool_call_start, on_tool_call_finish, on_finish).
  Span hierarchy matches upstream AI SDK: `ai.generateText` →
  `ai.generateText.doGenerate` → `ai.toolCall`.
```

**Step 3: Commit**

```
docs: mark telemetry as done in v2 roadmap, add changelog entry
```

---

## Implementation Notes

### Zero-overhead when disabled

The critical performance property: when `telemetry` is `None` or `enabled = false`, no spans are created and no attribute data is serialized. The `select_attributes` function returns `[]` immediately. The `maybe_span` helper skips `enter_span` entirely. The `notify_*` functions return `Lwt.return_unit` without iterating integrations. This matches upstream's noop tracer pattern.

### Span lifecycle for streaming

In `stream_text`, the root span is opened synchronously before `Lwt.async` and closed asynchronously inside the `finish_stream` helper or the error handler. This means the root span's lifetime covers the entire stream consumption. Step spans are similarly async — opened before `Language_model.stream`, closed after `consume_provider_stream`.

### Attribute key compatibility

All attribute keys use the exact upstream names (camelCase): `ai.model.provider`, `ai.settings.maxOutputTokens`, `gen_ai.request.model`, etc. This ensures compatibility with OpenTelemetry semantic conventions and any tooling that expects these keys.

### Usage token details

The upstream SDK records detailed token breakdowns (`ai.usage.inputTokenDetails.cacheReadTokens`, etc.). Our `Usage.t` currently only has `input_tokens`, `output_tokens`, `total_tokens`. We record what we have. When `Usage.t` gains detail fields (provider metadata from Anthropic includes these), the telemetry attributes can be extended without API changes.

### trace collector setup is the user's responsibility

The SDK only instruments with `Trace_core.enter_span` / `exit_span`. The application is responsible for installing a collector:
- `trace-tef` for Chrome Trace Format files (viewable in Perfetto UI)
- `opentelemetry.trace` for OTel/OTLP export (Jaeger, Datadog, etc.)
- Custom collector via `Trace_core.Collector.Callbacks.make`

This separation matches both the `trace` library's design philosophy and the upstream SDK's approach (where the user provides a `Tracer`).
