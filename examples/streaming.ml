(** Streaming generation example.

    Streams text tokens as they arrive from the model.
    Set ANTHROPIC_API_KEY environment variable before running.

    Usage: dune exec examples/streaming.exe *)

let () =
  Lwt_main.run
    begin
      let claude = Ai_provider_anthropic.model "claude-sonnet-4-6" in

      let opts =
        Ai_provider.Call_options.default
          ~prompt:
            [
              Ai_provider.Prompt.System { content = "You are a creative storyteller." };
              Ai_provider.Prompt.User
                {
                  content =
                    [
                      Text
                        { text = "Write a haiku about OCaml."; provider_options = Ai_provider.Provider_options.empty };
                    ];
                };
            ]
      in

      (* Start streaming *)
      let%lwt result = Ai_provider.Language_model.stream claude opts in

      (* Consume stream parts as they arrive *)
      let%lwt () =
        Lwt_stream.iter
          (fun (part : Ai_provider.Stream_part.t) ->
            match part with
            | Stream_start _ -> ()
            | Text { text } ->
              print_string text;
              flush stdout
            | Reasoning { text } ->
              Printf.printf "[thinking: %s]" text;
              flush stdout
            | Tool_call_delta { args_text_delta; _ } ->
              print_string args_text_delta;
              flush stdout
            | Tool_call_finish _ -> print_newline ()
            | File _ -> Printf.printf "[file]\n"
            | Source { url; _ } -> Printf.printf "[source: %s]\n" url
            | Finish { finish_reason; usage } ->
              Printf.printf "\n\n--- Done ---\n";
              Printf.printf "Finish: %s\n" (Ai_provider.Finish_reason.to_string finish_reason);
              Printf.printf "Tokens: %d in / %d out\n" usage.input_tokens usage.output_tokens
            | Error { error } -> Printf.eprintf "Error: %s\n" (Ai_provider.Provider_error.to_string error)
            | Provider_metadata _ -> ())
          result.stream
      in

      Lwt.return_unit
    end
