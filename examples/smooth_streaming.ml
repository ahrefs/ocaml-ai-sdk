(** Smooth streaming text generation.

    Demonstrates all [Smooth_stream] chunking modes — word, line, regex,
    Unicode segmenter, and custom — each applied to a separate streaming
    request. Matches the upstream AI SDK's [smoothStream].

    Compare with [stream_chat.ml] which prints raw (unsmoothed) tokens.

    Set ANTHROPIC_API_KEY environment variable before running.

    Usage: dune exec examples/smooth_streaming.exe *)

let model = Ai_provider_anthropic.model "claude-haiku-4-5"
let prompt = "Write exactly 10 short sentences about OCaml. Make the second half of them in CJK"
let system = "You are a concise technical writer. No markdown."

let stream_with ~label ~transform =
  Printf.printf "--- %s ---\n\n%!" label;
  let result = Ai_core.Stream_text.stream_text ~model ~system ~prompt ~transform () in
  let%lwt () =
    Lwt_stream.iter
      (fun text ->
        print_string text;
        flush stdout)
      result.text_stream
  in
  Printf.printf "\n\n%!";
  Lwt.return_unit

let () =
  Lwt_main.run
    begin
      (* Word-by-word (default) *)
    let%lwt () = stream_with ~label:"Word chunking (default)" ~transform:(Ai_core.Smooth_stream.create ()) in

    (* Line-by-line *)
    let%lwt () = stream_with ~label:"Line chunking" ~transform:(Ai_core.Smooth_stream.create ~chunking:Line ()) in

    (* Regex: sentence boundaries (period + space) *)
    let re = Re2.create_exn {|\.\s+|} in
    let%lwt () =
      stream_with ~label:"Regex chunking (sentence boundaries)"
        ~transform:(Ai_core.Smooth_stream.create ~chunking:(Regex re) ())
    in

    (* Unicode segmenter (UAX#29) — best for CJK *)
    let%lwt () =
      stream_with ~label:"Segmenter chunking (Unicode UAX#29)"
        ~transform:(Ai_core.Smooth_stream.create ~chunking:Segmenter ())
    in

    (* Custom: 10-character fixed-size chunks *)
    let chunker buf =
      match String.length buf >= 10 with
      | true -> Some (String.sub buf 0 10)
      | false -> None
    in
    let%lwt () =
      stream_with ~label:"Custom chunking (10-char blocks)"
        ~transform:(Ai_core.Smooth_stream.create ~chunking:(Custom chunker) ())
    in

    Printf.printf "--- All done ---\n";
    Lwt.return_unit
    end
