(** Non-streaming text generation example using the Core SDK.

    Set ANTHROPIC_API_KEY environment variable before running.

    Usage: dune exec examples/generate.exe *)

let () =
  Lwt_main.run
    begin
      (* Model_catalog provides type-safe model selection with capabilities *)
    let model_id = Ai_provider_anthropic.Model_catalog.(to_model_id Claude_haiku_4_5) in
    let model = Ai_provider_anthropic.model model_id in
    let%lwt result =
      Ai_core.Generate_text.generate_text ~model ~system:"You are a helpful assistant. Be concise."
        ~prompt:"What are the three primary colors?" ()
    in
    Printf.printf "%s\n" result.text;
    Printf.printf "\n--- Metadata ---\n";
    Printf.printf "Finish: %s\n" (Ai_provider.Finish_reason.to_string result.finish_reason);
    Printf.printf "Tokens: %d in / %d out\n" result.usage.input_tokens result.usage.output_tokens;
    Printf.printf "Steps: %d\n" (List.length result.steps);
    Lwt.return_unit
    end
