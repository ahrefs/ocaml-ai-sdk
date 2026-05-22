(** Prompt caching demo.

    Three sequential calls with the same large system prompt:
    - Call 1: [generate_text] writes the system prompt to Anthropic's
      ephemeral cache.
    - Call 2: [generate_text] reads it back.
    - Call 3: [stream_text] also reads it back — proving the streaming
      result surfaces the same cache metrics as the non-streaming path
      via [Stream_text_result.provider_metadata].

    The system prompt has to clear the model's minimum cacheable token
    threshold (4,096 tokens for Sonnet 4.6 / Opus, 1,024 for older
    Sonnet models). We pad it with placeholder text to be safe.

    Set ANTHROPIC_API_KEY before running:
    {v
      dune exec examples/prompt_caching.exe
    v} *)

let padding_lines n =
  (* Roughly 4 tokens per line; 1500 lines -> ~6k tokens, well above the
     4,096 threshold for the latest models. *)
  let buf = Buffer.create (n * 80) in
  for i = 1 to n do
    Buffer.add_string buf
      (Printf.sprintf "Section %d: This is reference material the assistant should ground its answers in.\n" i)
  done;
  Buffer.contents buf

let cached_system_prompt =
  String.concat "\n"
    [
      "You are a documentation assistant. Use the reference material below.";
      "";
      "--- BEGIN REFERENCE MATERIAL ---";
      padding_lines 1500;
      "--- END REFERENCE MATERIAL ---";
      "";
      "Answer concisely. One sentence per response.";
    ]

let cache_provider_options =
  Ai_provider_anthropic.Cache_control_options.with_cache_control
    ~cache_control:Ai_provider_anthropic.Cache_control.ephemeral Ai_provider.Provider_options.empty

let print_metrics ~label ~input_tokens ~output_tokens ~provider_metadata =
  Printf.printf "\n=== %s ===\n" label;
  Printf.printf "input_tokens:           %d\n" input_tokens;
  Printf.printf "output_tokens:          %d\n" output_tokens;
  match Option.bind provider_metadata Ai_provider_anthropic.Convert_usage.of_provider_metadata with
  | None -> Printf.printf "(no anthropic cache metrics on this response)\n"
  | Some u ->
    let opt label v =
      match v with
      | None -> Printf.printf "%-24s—\n" (label ^ ":")
      | Some n -> Printf.printf "%-24s%d\n" (label ^ ":") n
    in
    opt "cache_creation_input" u.cache_creation_input_tokens;
    opt "cache_read_input" u.cache_read_input_tokens

let () =
  Lwt_main.run
    begin
      let open Ai_provider_anthropic.Model_catalog in
      let model = Ai_provider_anthropic.model (to_model_id Claude_sonnet_4_6) in

      Printf.printf "Sending request 1 via generate_text (cold cache)...\n%!";
      let%lwt r1 =
        Ai_core.Generate_text.generate_text ~model ~system:cached_system_prompt
          ~system_provider_options:cache_provider_options ~prompt:"In one sentence, what should I do first?" ()
      in
      let last_step1 = List.nth r1.steps (List.length r1.steps - 1) in
      print_metrics ~label:"Request 1 (cache write expected)" ~input_tokens:r1.usage.input_tokens
        ~output_tokens:r1.usage.output_tokens ~provider_metadata:last_step1.provider_metadata;

      Printf.printf "\nSending request 2 via generate_text (warm cache)...\n%!";
      let%lwt r2 =
        Ai_core.Generate_text.generate_text ~model ~system:cached_system_prompt
          ~system_provider_options:cache_provider_options ~prompt:"In one sentence, what should I do second?" ()
      in
      let last_step2 = List.nth r2.steps (List.length r2.steps - 1) in
      print_metrics ~label:"Request 2 (cache read expected)" ~input_tokens:r2.usage.input_tokens
        ~output_tokens:r2.usage.output_tokens ~provider_metadata:last_step2.provider_metadata;

      Printf.printf "\nSending request 3 via stream_text (warm cache, streaming)...\n%!";
      let stream_result =
        Ai_core.Stream_text.stream_text ~model ~system:cached_system_prompt
          ~system_provider_options:cache_provider_options ~prompt:"In one sentence, what should I do third?" ()
      in
      let%lwt () =
        Lwt_stream.iter
          (fun s ->
            print_string s;
            flush stdout)
          stream_result.text_stream
      in
      Printf.printf "\n%!";
      let%lwt usage = stream_result.usage in
      let%lwt provider_metadata = stream_result.provider_metadata in
      print_metrics ~label:"Request 3 (streaming, cache read expected)" ~input_tokens:usage.input_tokens
        ~output_tokens:usage.output_tokens ~provider_metadata;

      Printf.printf "\n%!";
      Lwt.return_unit
    end
