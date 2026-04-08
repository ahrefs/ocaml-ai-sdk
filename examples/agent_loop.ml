(** Agent-style multi-step tool loop with stop conditions.

    Demonstrates using [stop_when] to control when the tool loop terminates,
    matching the upstream AI SDK's [stopWhen] parameter.

    Set ANTHROPIC_API_KEY environment variable before running.

    Usage: dune exec examples/agent_loop.exe *)

let () =
  Lwt_main.run
    begin
      let model_id = Ai_provider_anthropic.Model_catalog.(to_model_id Claude_haiku_4_5) in
      let model = Ai_provider_anthropic.model model_id in

      (* Define tools *)
      let search_tool =
        Ai_core.Core_tool.create ~description:"Search for information on a topic"
          ~parameters:
            (`Assoc
               [
                 "type", `String "object";
                 "properties", `Assoc [ "query", `Assoc [ "type", `String "string" ] ];
                 "required", `List [ `String "query" ];
               ])
          ~execute:(fun args ->
            let query = try Yojson.Basic.Util.(member "query" args |> to_string) with _ -> "unknown" in
            Printf.printf "  [tool] Searching for: %s\n%!" query;
            Lwt.return (`String (Printf.sprintf "Results for '%s': OCaml is a functional programming language." query)))
          ()
      in
      let summarize_tool =
        Ai_core.Core_tool.create ~description:"Summarize the gathered information into a final answer"
          ~parameters:
            (`Assoc
               [
                 "type", `String "object";
                 "properties", `Assoc [ "summary", `Assoc [ "type", `String "string" ] ];
                 "required", `List [ `String "summary" ];
               ])
          ~execute:(fun args ->
            let summary = try Yojson.Basic.Util.(member "summary" args |> to_string) with _ -> "No summary" in
            Printf.printf "  [tool] Summary: %s\n%!" summary;
            Lwt.return (`String summary))
          ()
      in

      Printf.printf "--- Agent loop with stop_when ---\n\n%!";

      let%lwt result =
        Ai_core.Generate_text.generate_text ~model
          ~system:
            "You are a research assistant. Use the search tool to find information, then use the summarize tool when \
             you have enough information to answer."
          ~prompt:"What is OCaml? Search for it and then summarize."
          ~tools:[ "search", search_tool; "summarize", summarize_tool ]
          ~max_steps:10
          ~stop_when:
            [
              (* Stop after 5 steps as a safety limit *)
              Ai_core.Stop_condition.step_count_is 5;
              (* Or stop when the model calls the summarize tool *)
              Ai_core.Stop_condition.has_tool_call "summarize";
            ]
          ~on_step_finish:(fun step ->
            Printf.printf "Step finished: %d tool call(s), finish_reason=%s\n%!" (List.length step.tool_calls)
              (Ai_provider.Finish_reason.to_string step.finish_reason))
          ()
      in

      Printf.printf "\n--- Result ---\n";
      Printf.printf "Text: %s\n" result.text;
      Printf.printf "Steps: %d\n" (List.length result.steps);
      Printf.printf "Tool calls: %d\n" (List.length result.tool_calls);
      Printf.printf "Finish: %s\n" (Ai_provider.Finish_reason.to_string result.finish_reason);
      Printf.printf "Tokens: %d in / %d out\n" result.usage.input_tokens result.usage.output_tokens;

      Lwt.return_unit
    end
