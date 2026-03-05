(** Streaming text generation using the Core SDK.

    Shows text tokens as they arrive, using the full stream.
    Set ANTHROPIC_API_KEY environment variable before running.

    Usage: dune exec examples/stream_chat.exe *)

let () =
  Lwt_main.run
    begin
      let model = Ai_provider_anthropic.model "claude-sonnet-4-6" in
      let result =
        Ai_core.Stream_text.stream_text ~model ~system:"You are a creative writer."
          ~prompt:"Write a short poem about functional programming." ()
      in
      (* Consume text stream — prints tokens as they arrive *)
      let%lwt () =
        Lwt_stream.iter
          (fun text ->
            print_string text;
            flush stdout)
          result.text_stream
      in
      (* Print final stats *)
      let%lwt usage = result.usage in
      let%lwt fr = result.finish_reason in
      Printf.printf "\n\n--- Done ---\n";
      Printf.printf "Finish: %s\n" (Ai_provider.Finish_reason.to_string fr);
      Printf.printf "Tokens: %d in / %d out\n" usage.input_tokens usage.output_tokens;
      Lwt.return_unit
    end
