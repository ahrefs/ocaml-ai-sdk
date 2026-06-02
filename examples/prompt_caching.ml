(** Prompt caching demo.

    Three calls with the same large system prompt: [generate_text] writes the
    cache, [generate_text] reads it back, then [stream_text] reads it again to
    confirm the streaming path also surfaces cache metrics on its
    [provider_metadata] promise.

    Set [ANTHROPIC_API_KEY] before running:
    [dune exec examples/prompt_caching.exe] *)

let big_system_prompt =
  let buf = Buffer.create 8192 in
  Buffer.add_string buf "You are a documentation assistant. Reference material:\n";
  for i = 1 to 1500 do
    Buffer.add_string buf (Printf.sprintf "Section %d: padding to exceed the 4096-token cache threshold.\n" i)
  done;
  Buffer.contents buf

let cache_po =
  Ai_provider_anthropic.Cache_control_options.with_cache_control
    ~cache_control:Ai_provider_anthropic.Cache_control.ephemeral Ai_provider.Provider_options.empty

let model () = Ai_provider_anthropic.model (Ai_provider_anthropic.Model_catalog.to_model_id Claude_sonnet_4_6)

let print_metrics label ~input ~output pm =
  let cache = Option.bind pm Ai_provider_anthropic.Convert_usage.of_provider_metadata in
  let show f =
    match cache with
    | Some u -> Option.fold ~none:"-" ~some:string_of_int (f u)
    | None -> "-"
  in
  Printf.printf "[%s] input=%d output=%d cache_creation=%s cache_read=%s\n%!" label input output
    (show (fun u -> u.cache_creation_input_tokens))
    (show (fun u -> u.cache_read_input_tokens))

let run_generate label prompt =
  let%lwt r =
    Ai_core.Generate_text.generate_text ~model:(model ()) ~system:big_system_prompt ~system_provider_options:cache_po
      ~prompt ()
  in
  let last = List.nth r.steps (List.length r.steps - 1) in
  print_metrics label ~input:r.usage.input_tokens ~output:r.usage.output_tokens last.provider_metadata;
  Lwt.return_unit

let run_stream label prompt =
  let sr =
    Ai_core.Stream_text.stream_text ~model:(model ()) ~system:big_system_prompt ~system_provider_options:cache_po
      ~prompt ()
  in
  let%lwt () = Lwt_stream.iter (fun _ -> ()) sr.text_stream in
  let%lwt usage = sr.usage in
  let%lwt pm = sr.provider_metadata in
  print_metrics label ~input:usage.input_tokens ~output:usage.output_tokens pm;
  Lwt.return_unit

let () =
  Lwt_main.run
    (let%lwt () = run_generate "cold" "What's first?" in
     let%lwt () = run_generate "warm" "What's second?" in
     run_stream "warm-stream" "What's third?")
