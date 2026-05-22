(** Prompt caching demo.

    Sends two sequential generate_text calls with the same large system
    prompt. The first call writes the system prompt to Anthropic's
    ephemeral cache; the second call reads it back. We print the
    [usage] for each call so the cache_creation / cache_read columns are
    visible side by side.

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

let print_usage ~label (result : Ai_provider.Generate_result.t) =
  Printf.printf "\n=== %s ===\n" label;
  Printf.printf "input_tokens:           %d\n" result.usage.input_tokens;
  Printf.printf "output_tokens:          %d\n" result.usage.output_tokens;
  (match Ai_provider_anthropic.Convert_usage.of_provider_metadata result.provider_metadata with
  | None -> Printf.printf "(no anthropic cache metrics on this response)\n"
  | Some u ->
    let opt label v =
      match v with
      | None -> Printf.printf "%-24s—\n" (label ^ ":")
      | Some n -> Printf.printf "%-24s%d\n" (label ^ ":") n
    in
    opt "cache_creation_input" u.cache_creation_input_tokens;
    opt "cache_read_input" u.cache_read_input_tokens)

let user_message text =
  Ai_provider.Prompt.User
    { content = [ Text { text; provider_options = Ai_provider.Provider_options.empty } ] }

let system_message_with_cache content =
  let provider_options =
    Ai_provider_anthropic.Cache_control_options.with_cache_control
      ~cache_control:Ai_provider_anthropic.Cache_control.ephemeral Ai_provider.Provider_options.empty
  in
  Ai_provider.Prompt.System { content; provider_options }

let run ~model ~question =
  let opts =
    Ai_provider.Call_options.default ~prompt:[ system_message_with_cache cached_system_prompt; user_message question ]
  in
  Ai_provider.Language_model.generate model opts

let () =
  Lwt_main.run
    begin
      let open Ai_provider_anthropic.Model_catalog in
      let model = Ai_provider_anthropic.model (to_model_id Claude_sonnet_4_6) in
      Printf.printf "Sending request 1 (cold cache)...\n%!";
      let%lwt r1 = run ~model ~question:"In one sentence, what should I do first?" in
      print_usage ~label:"Request 1 (cache write expected)" r1;
      Printf.printf "\nSending request 2 (warm cache)...\n%!";
      let%lwt r2 = run ~model ~question:"In one sentence, what should I do second?" in
      print_usage ~label:"Request 2 (cache read expected)" r2;
      Printf.printf "\n%!";
      Lwt.return_unit
    end
