(** Telemetry logging example.

    Demonstrates two ways to observe AI SDK operations:

    1. {b Integration callbacks} — structured lifecycle events
       ([on_start], [on_tool_call_start], [on_tool_call_finish],
       [on_step_finish], [on_finish]) for application-level logging,
       metrics, and third-party integrations (Langfuse, Helicone, etc.).

    2. {b Trace spans} — OpenTelemetry-compatible spans via the
       [trace] library for distributed tracing backends (Jaeger,
       Zipkin, Datadog, etc.). Install any [trace]-compatible collector;
       for example, [trace-tef] writes Chrome Trace Format JSON
       viewable in {{:https://ui.perfetto.dev} Perfetto UI}, or
       [opentelemetry.trace] exports to OTLP collectors.

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
            event.model.model_id (List.length event.messages) (List.length event.tools);
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
             `Assoc [ "city", `Assoc [ "type", `String "string"; "description", `String "City name, e.g. 'Paris'" ] ] );
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
  (* Install trace-tef collector — writes Chrome Trace Format JSON.
     Open the output file in https://ui.perfetto.dev to visualize
     the span hierarchy (ai.generateText → ai.generateText.doGenerate → ai.toolCall). *)
  Trace_tef.setup ~out:(`File "ai-trace.json") ();
  Fun.protect ~finally:Trace_core.shutdown (fun () ->
    Lwt_main.run
      begin
        let model = Ai_provider_anthropic.model Ai_provider_anthropic.Model_catalog.(to_model_id Claude_haiku_4_5) in

        (* Create telemetry settings with our logging integration.
         The trace-tef collector captures spans automatically;
         the integration callbacks provide structured lifecycle events. *)
        let telemetry =
          Ai_core.Telemetry.create ~enabled:true ~function_id:"weather-chat"
            ~metadata:[ "example", `String "telemetry_logging"; "user_id", `String "demo-user" ]
            ~integrations:[ logging_integration ] ()
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
        Printf.printf "Total: %d input / %d output tokens, %d steps\n\n%!" result.usage.input_tokens
          result.usage.output_tokens (List.length result.steps);
        Printf.printf "Trace written to ai-trace.json — open in https://ui.perfetto.dev\n%!";

        Lwt.return_unit
      end)
