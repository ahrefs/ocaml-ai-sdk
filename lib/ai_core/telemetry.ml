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
        match t.record_outputs with
        | true -> Some (key, f ())
        | false -> None)
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
  let metadata_attrs = List.map (fun (k, v) -> Printf.sprintf "ai.telemetry.metadata.%s" k, v) t.metadata in
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
  |> fun acc ->
  match stop_sequences with
  | Some seqs when seqs <> [] -> ("ai.settings.stopSequences", `String (String.concat "," seqs)) :: acc
  | Some _ -> acc
  | None -> acc

(* ---- Lwt Span Helpers ---- *)

let with_span_lwt ?parent ~data name f =
  let sp =
    Trace_core.enter_span ~__FILE__ ~__LINE__ ~flavor:`Async ?parent:(Option.map Option.some parent) ~data name
  in
  Lwt.catch
    (fun () ->
      let%lwt result = f sp in
      Trace_core.exit_span sp;
      Lwt.return result)
    (fun exn ->
      Trace_core.add_data_to_span sp [ "error", `Bool true; "error.message", `String (Printexc.to_string exn) ];
      Trace_core.exit_span sp;
      raise exn)

(* ---- Optional Attribute Helpers ---- *)

let opt_attr key f = function
  | Some v -> [ key, f v ]
  | None -> []

let opt_string_attr key = opt_attr key (fun v -> `String v)
let opt_int_attr key = opt_attr key (fun v -> `Int v)
let opt_float_attr key = opt_attr key (fun v -> `Float v)

(* ---- Conditional Helpers ---- *)

let maybe_span telemetry name ~data f =
  match telemetry with
  | Some t when t.enabled -> with_span_lwt ~data name f
  | _ -> f Trace_core.Collector.dummy_span

let maybe_notify telemetry f =
  match telemetry with
  | Some t when t.enabled -> f t
  | _ -> Lwt.return_unit

let make_model_info ~provider ~model_id = { provider; model_id }

let tool_calls_to_json_string (tool_calls : Generate_text_result.tool_call list) =
  let tc_json =
    List.map
      (fun (tc : Generate_text_result.tool_call) ->
        `Assoc [ "toolCallId", `String tc.tool_call_id; "toolName", `String tc.tool_name; "args", tc.args ])
      tool_calls
  in
  Yojson.Basic.to_string (`List tc_json)

(* ---- Global Integration Registry ---- *)

let global_integrations : integration list ref = ref []

let register_global_integration integration = global_integrations := integration :: !global_integrations

let clear_global_integrations () = global_integrations := []

(* ---- Integration Notification ---- *)

let all_integrations t = t.integrations @ List.rev !global_integrations

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
