(** Extended thinking example.

    Enables Claude's extended thinking via Anthropic-specific provider options.
    Demonstrates how the GADT-based Provider_options flow through the abstraction.
    Set ANTHROPIC_API_KEY environment variable before running.

    Usage: dune exec examples/thinking.exe *)

let () =
  Lwt_main.run
    begin
      let claude = Ai_provider_anthropic.model "claude-sonnet-4-6" in

      (* Configure extended thinking via type-safe provider options *)
      let budget = Ai_provider_anthropic.Thinking.budget_exn 4096 in
      let thinking : Ai_provider_anthropic.Thinking.t = { enabled = true; budget_tokens = budget } in
      let anthropic_opts = { Ai_provider_anthropic.Anthropic_options.default with thinking = Some thinking } in
      let provider_options = Ai_provider_anthropic.Anthropic_options.to_provider_options anthropic_opts in

      let opts =
        {
          (Ai_provider.Call_options.default
             ~prompt:
               [
                 Ai_provider.Prompt.User
                   {
                     content =
                       [
                         Text
                           {
                             text = "How many r's are in the word 'strawberry'?";
                             provider_options = Ai_provider.Provider_options.empty;
                           };
                       ];
                   };
               ])
          with
          provider_options;
        }
      in

      let%lwt result = Ai_provider.Language_model.generate claude opts in

      (* The response may include reasoning blocks before the answer *)
      List.iter
        (fun (part : Ai_provider.Content.t) ->
          match part with
          | Reasoning { text; _ } -> Printf.printf "[Thinking]\n%s\n[/Thinking]\n\n" text
          | Text { text } -> Printf.printf "%s\n" text
          | Tool_call _ -> Printf.printf "[Tool call]\n"
          | File _ -> Printf.printf "[File]\n")
        result.content;

      Printf.printf "\n--- Metadata ---\n";
      Printf.printf "Tokens: %d in / %d out\n" result.usage.input_tokens result.usage.output_tokens;

      Lwt.return_unit
    end
