(** One-shot generation example.

    Sends a single prompt and prints the response.
    Set ANTHROPIC_API_KEY environment variable before running.

    Usage: dune exec examples/one_shot.exe *)

let () =
  Lwt_main.run
    begin
      (* Create a model — uses ANTHROPIC_API_KEY from env *)
    let claude = Ai_provider_anthropic.model "claude-sonnet-4-6" in

    (* Build the prompt with type-safe message construction *)
    let opts =
      Ai_provider.Call_options.default
        ~prompt:
          [
            Ai_provider.Prompt.System { content = "You are a helpful assistant. Be concise." };
            Ai_provider.Prompt.User
              {
                content =
                  [
                    Text
                      {
                        text = "What is the capital of France? One word.";
                        provider_options = Ai_provider.Provider_options.empty;
                      };
                  ];
              };
          ]
    in

    (* Generate a response *)
    let%lwt result = Ai_provider.Language_model.generate claude opts in

    (* Print each content block *)
    List.iter
      (fun (part : Ai_provider.Content.t) ->
        match part with
        | Text { text } -> Printf.printf "%s\n" text
        | Tool_call { tool_name; args; _ } -> Printf.printf "[Tool call: %s(%s)]\n" tool_name args
        | Reasoning { text; _ } -> Printf.printf "[Thinking: %s]\n" text
        | File _ -> Printf.printf "[File received]\n")
      result.content;

    (* Print metadata *)
    Printf.printf "\n--- Metadata ---\n";
    Printf.printf "Model: %s\n"
      (match result.response.model with
      | Some m -> m
      | None -> "unknown");
    Printf.printf "Finish reason: %s\n" (Ai_provider.Finish_reason.to_string result.finish_reason);
    Printf.printf "Tokens: %d in / %d out\n" result.usage.input_tokens result.usage.output_tokens;

    Lwt.return_unit
    end
