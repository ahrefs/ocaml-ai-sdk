(** OpenRouter prompt caching demo.

    Demonstrates both cache-control modes exposed by the OpenRouter provider:

    1. {b Top-level mode} — sets [Openrouter_options.cache_control]; serialized
       as the request body's top-level [cache_control] field. Only effective
       when OpenRouter routes to Anthropic directly.
    2. {b Explicit-breakpoint mode} — passes a per-part marker via
       [system_provider_options] using
       [Openrouter_cache_control_options.with_cache_control]. Works on
       Anthropic explicit, Gemini explicit, Alibaba Qwen, DeepSeek-v3.2.

    Each mode runs two [generate_text] calls back-to-back with the same large
    system prompt and prints [input] / [output] / [cache_read_tokens] /
    [cache_write_tokens] per call.

    Set [OPENROUTER_API_KEY] before running:
    [dune exec examples/openrouter_prompt_caching.exe] *)

module OR = Ai_provider_openrouter

let big_system_prompt =
  let buf = Buffer.create 8192 in
  Buffer.add_string buf "You are a documentation assistant. Reference material:\n";
  for i = 1 to 1500 do
    Buffer.add_string buf
      (Printf.sprintf "Section %d: padding to exceed the 4096-token cache threshold.\n" i)
  done;
  Buffer.contents buf

let model_id = "anthropic/claude-3.5-sonnet"

let extract_or_metadata pm =
  Stdlib.Option.bind pm (fun po -> Ai_provider.Provider_options.find OR.Convert_usage.Openrouter_usage po)

let print_metrics label ~input ~output pm =
  let md = extract_or_metadata pm in
  let cache_read = match md with Some m -> string_of_int m.cache_read_tokens | None -> "-" in
  let cache_write = match md with Some m -> string_of_int m.cache_write_tokens | None -> "-" in
  Printf.printf "[%s] input=%d output=%d cache_read=%s cache_write=%s\n%!" label input output cache_read
    cache_write

(* --- Mode 1: top-level cache_control --- *)

let top_level_provider_options =
  let opts =
    {
      OR.Openrouter_options.default with
      cache_control = Some { type_ = "ephemeral"; ttl = Some "5m" };
    }
  in
  OR.Openrouter_options.to_provider_options opts

let run_top_level label prompt =
  let model = OR.language_model ~model:model_id () in
  let%lwt r =
    Ai_core.Generate_text.generate_text ~model ~system:big_system_prompt
      ~provider_options:top_level_provider_options ~prompt ()
  in
  let last = List.nth r.steps (List.length r.steps - 1) in
  print_metrics label ~input:r.usage.input_tokens ~output:r.usage.output_tokens last.provider_metadata;
  Lwt.return_unit

(* --- Mode 2: explicit per-part breakpoint on the system message --- *)

let explicit_system_provider_options =
  OR.Cache_control_options.with_cache_control ~cache_control:OR.Cache_control.ephemeral
    Ai_provider.Provider_options.empty

let run_explicit label prompt =
  let model = OR.language_model ~model:model_id () in
  let%lwt r =
    Ai_core.Generate_text.generate_text ~model ~system:big_system_prompt
      ~system_provider_options:explicit_system_provider_options ~prompt ()
  in
  let last = List.nth r.steps (List.length r.steps - 1) in
  print_metrics label ~input:r.usage.input_tokens ~output:r.usage.output_tokens last.provider_metadata;
  Lwt.return_unit

let () =
  Lwt_main.run
    (let%lwt () = Lwt_io.printl "=== Top-level cache_control (Anthropic automatic) ===" in
     let%lwt () = run_top_level "top-cold" "What's first?" in
     let%lwt () = run_top_level "top-warm" "What's second?" in
     let%lwt () = Lwt_io.printl "=== Explicit breakpoint via system_provider_options ===" in
     let%lwt () = run_explicit "explicit-cold" "What's third?" in
     run_explicit "explicit-warm" "What's fourth?")
