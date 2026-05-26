(** Prompt caching demo.

    Two [generate_text] calls with the same large system prompt: the first
    writes the prompt to Anthropic's ephemeral cache, the second reads it
    back. Cache metrics surface via [step.provider_metadata].

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

let run label prompt =
  let model = Ai_provider_anthropic.model (Ai_provider_anthropic.Model_catalog.to_model_id Claude_sonnet_4_6) in
  let%lwt r =
    Ai_core.Generate_text.generate_text ~model ~system:big_system_prompt ~system_provider_options:cache_po ~prompt ()
  in
  let last = List.nth r.steps (List.length r.steps - 1) in
  let cache =
    Option.bind last.provider_metadata Ai_provider_anthropic.Convert_usage.of_provider_metadata
  in
  Printf.printf "[%s] input=%d output=%d cache_creation=%s cache_read=%s\n%!" label r.usage.input_tokens
    r.usage.output_tokens
    (match cache with Some u -> Option.fold ~none:"-" ~some:string_of_int u.cache_creation_input_tokens | None -> "-")
    (match cache with Some u -> Option.fold ~none:"-" ~some:string_of_int u.cache_read_input_tokens | None -> "-");
  Lwt.return_unit

let () = Lwt_main.run (let%lwt () = run "cold" "What's first?" in run "warm" "What's second?")
