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
    no attributes are evaluated at all (zero serialization cost).

    {2 Upstream parity gaps}

    The following upstream attributes are not yet emitted:

    - [ai.response.timestamp]: our [Generate_result.response_info] does
      not carry timestamps.
    - [ai.response.id], [ai.response.model] on {b stream} step spans:
      streaming does not expose per-step response metadata (would require
      changes to [Stream_result]).  These are emitted on generate step spans.
    - [ai.usage.inputTokenDetails.*], [ai.usage.outputTokenDetails.*]:
      our [Usage.t] only has [input_tokens], [output_tokens],
      [total_tokens].  When the provider-level type gains detail fields
      (Anthropic already returns them in provider metadata), the span
      attributes can be extended without API changes.
    - [onStepStart] integration callback: upstream added this; we only
      have [on_step_finish].
    - [gen_ai.response.finish_reasons]: upstream emits a string array
      ([["stop"]]).  [Trace_core.user_data] has no array variant, so we
      emit a plain string (["stop"]).
    - [ai.prompt] on root spans: upstream serializes full message content
      (gated by [record_inputs]).  We emit placeholder strings
      (["<message>"]) to avoid serializing large payloads into span data.
      The full messages are available via integration callbacks. *)

(** {1 Types} *)

(** Model info for callback events. *)
type model_info = {
  provider : string;
  model_id : string;
}

(** Lifecycle callbacks for telemetry events.

    All callbacks are optional — implement only the ones you need.
    Errors in callbacks are caught and ignored (they must not break
    the generation pipeline). Callbacks are called in order:
    global integrations first, then per-call integrations
    (matching upstream). *)
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
val assemble_operation_name : operation_id:string -> t -> (string * Trace_core.user_data) list

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

(** {1 Optional Attribute Helpers}

    Build a single-element attribute list from an [option] value,
    or [[]] when [None]. Useful for building span data from optional
    call settings and response fields. *)

val opt_attr : string -> ('a -> Trace_core.user_data) -> 'a option -> (string * Trace_core.user_data) list
val opt_string_attr : string -> string option -> (string * Trace_core.user_data) list
val opt_int_attr : string -> int option -> (string * Trace_core.user_data) list
val opt_float_attr : string -> float option -> (string * Trace_core.user_data) list

(** {1 Lwt Span Helpers} *)

(** [with_span_lwt name ~data f] opens a span, runs [f span], and closes
    the span when the Lwt promise resolves or fails. On failure, the
    exception message is recorded on the span via [add_data_to_span]
    before re-raising.

    Uses [Trace_core.enter_span] / [exit_span] (not [with_span]) so
    the span stays open across Lwt yield points.

    When no [Trace_core] collector is installed, the span is a dummy
    and the overhead is a single allocation + [Lwt.catch]. *)
val with_span_lwt :
  ?parent:Trace_core.span ->
  data:(unit -> (string * Trace_core.user_data) list) ->
  string ->
  (Trace_core.span -> 'a Lwt.t) ->
  'a Lwt.t

(** {1 Conditional Helpers}

    Convenience wrappers for use in [generate_text] and [stream_text].
    When telemetry is [None] or [enabled = false], these are zero-cost. *)

(** Conditionally wrap in a telemetry span. When telemetry is [None] or
    disabled, [f] is called with [Trace_core.Collector.dummy_span]. *)
val maybe_span :
  t option -> string -> data:(unit -> (string * Trace_core.user_data) list) -> (Trace_core.span -> 'a Lwt.t) -> 'a Lwt.t

(** Fire a telemetry notification when enabled; otherwise [Lwt.return_unit]. *)
val maybe_notify : t option -> (t -> unit Lwt.t) -> unit Lwt.t

(** Build a {!model_info} from provider and model ID strings. *)
val make_model_info : provider:string -> model_id:string -> model_info

(** Serialize tool calls to a JSON string for telemetry attributes. *)
val tool_calls_to_json_string : Generate_text_result.tool_call list -> string

(** {1 Precompute Helpers}

    One-shot telemetry setup shared by [generate_text] and [stream_text].
    Extracts model info, settings, and base attributes. When telemetry
    is [None] or disabled, returns zero-cost defaults. *)

(** Precomputed telemetry values, extracted once per operation. *)
type precomputed = {
  model_info : model_info;
  function_id_ : string option;
  metadata_ : (string * Trace_core.user_data) list;
  base_data : (string * Trace_core.user_data) list;
}

val precompute :
  operation_id:string ->
  model:(module Ai_provider.Language_model.S) ->
  ?max_output_tokens:int ->
  ?temperature:float ->
  ?top_p:float ->
  ?top_k:int ->
  ?stop_sequences:string list ->
  ?seed:int ->
  ?max_retries:int ->
  ?headers:(string * string) list ->
  t option ->
  precomputed

(** {1 Step Span Attribute Builders}

    Shared helpers that build span attributes for step spans
    ([doGenerate] / [doStream]) and tool call spans. These prevent
    attribute key drift between [generate_text] and [stream_text]. *)

(** Build request-side attributes for a step span. *)
val step_request_attrs :
  operation_id:string ->
  model_info:model_info ->
  current_messages:Ai_provider.Prompt.message list ->
  tools:(string * Core_tool.t) list ->
  tool_choice:Ai_provider.Tool_choice.t option ->
  ?max_output_tokens:int ->
  ?temperature:float ->
  ?top_p:float ->
  ?top_k:int ->
  ?stop_sequences:string list ->
  t ->
  (string * Trace_core.user_data) list

(** Build response-side attributes for a step span. *)
val step_response_attrs :
  text:string ->
  reasoning:string ->
  tool_calls:Generate_text_result.tool_call list ->
  finish_reason:Ai_provider.Finish_reason.t ->
  usage:Ai_provider.Usage.t ->
  ?response_id:string ->
  ?response_model:string ->
  t ->
  (string * Trace_core.user_data) list

(** Build final response attributes for the root span. *)
val final_response_attrs :
  text:string ->
  reasoning:string ->
  finish_reason:Ai_provider.Finish_reason.t ->
  usage:Ai_provider.Usage.t ->
  t ->
  (string * Trace_core.user_data) list

(** Build initial span data for a tool call span. *)
val tool_call_span_data :
  model_info:model_info ->
  tool_name:string ->
  tool_call_id:string ->
  args:Yojson.Basic.t ->
  t ->
  (string * Trace_core.user_data) list

(** Build result attributes to add to a tool call span after execution. *)
val tool_call_result_attrs : result:Yojson.Basic.t -> t -> (string * Trace_core.user_data) list

(** {1 Integration Values} *)

(** An empty integration with no callbacks. Useful as a starting
    point for building partial integrations:

    {[
      { Telemetry.no_integration with
        on_finish = Some (fun event -> ...);
      }
    ]} *)
val no_integration : integration

(** {1 Integration Notification}

    Notify all integrations (per-call + global) of an event.
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
