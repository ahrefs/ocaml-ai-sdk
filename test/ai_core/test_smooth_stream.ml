open Alcotest

(** Helper: collect all parts from a smooth_stream transform *)
let run_smooth ?chunking parts =
  let input_stream, push = Lwt_stream.create () in
  List.iter (fun p -> push (Some p)) parts;
  push None;
  let output = Ai_core.Smooth_stream.create ~delay_ms:0 ?chunking () input_stream in
  Lwt_main.run (Lwt_stream.to_list output)

(** Extract text from Text_delta parts *)
let text_deltas parts =
  List.filter_map
    (function
      | Ai_core.Text_stream_part.Text_delta { text; _ } -> Some text
      | _ -> None)
    parts

(** Extract text from Reasoning_delta parts *)
let reasoning_deltas parts =
  List.filter_map
    (function
      | Ai_core.Text_stream_part.Reasoning_delta { text; _ } -> Some text
      | _ -> None)
    parts

(* --- Word chunking --- *)

let test_word_chunking_basic () =
  let parts = run_smooth [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "Hello world foo" } ] in
  let texts = text_deltas parts in
  (check (list string)) "word chunks" [ "Hello "; "world "; "foo" ] texts

let test_word_chunking_incremental () =
  let parts =
    run_smooth
      [
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "Hel" };
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "lo " };
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "wor" };
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "ld " };
      ]
  in
  let texts = text_deltas parts in
  (check (list string)) "incremental words" [ "Hello "; "world " ] texts

let test_word_passthrough_non_text () =
  let parts =
    run_smooth
      [
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "Hello " };
        Ai_core.Text_stream_part.Start_step;
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "world " };
      ]
  in
  let has_start_step =
    List.exists
      (function
        | Ai_core.Text_stream_part.Start_step -> true
        | _ -> false)
      parts
  in
  (check bool) "start_step passes through" true has_start_step;
  let texts = text_deltas parts in
  (check (list string)) "text around event" [ "Hello "; "world " ] texts

let test_word_empty_input () =
  let parts = run_smooth [] in
  (check int) "empty" 0 (List.length parts)

(* --- Line chunking --- *)

let test_line_chunking () =
  let parts =
    run_smooth ~chunking:Ai_core.Smooth_stream.Line
      [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "line one\nline two\nthree" } ]
  in
  let texts = text_deltas parts in
  (check (list string)) "line chunks" [ "line one\n"; "line two\n"; "three" ] texts

let test_line_chunking_multiple_newlines () =
  let parts =
    run_smooth ~chunking:Ai_core.Smooth_stream.Line
      [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "a\n\nb" } ]
  in
  let texts = text_deltas parts in
  (check (list string)) "double newline" [ "a\n\n"; "b" ] texts

(* --- Regex chunking --- *)

let test_regex_chunking () =
  let re = Re2.create_exn {|\.\s+|} in
  let parts =
    run_smooth ~chunking:(Ai_core.Smooth_stream.Regex re)
      [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "Hello. World. End" } ]
  in
  let texts = text_deltas parts in
  (check (list string)) "sentence chunks" [ "Hello. "; "World. "; "End" ] texts

(* --- Segmenter chunking --- *)

let test_segmenter_english () =
  (* UAX#29 word segmentation: "Hello" " " "world" *)
  let parts =
    run_smooth ~chunking:Ai_core.Smooth_stream.Segmenter
      [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "Hello world" } ]
  in
  let texts = text_deltas parts in
  (check (list string)) "english words" [ "Hello"; " "; "world" ] texts

let test_segmenter_cjk_chinese () =
  (* UAX#29 segments CJK characters individually — the primary use-case for Segmenter *)
  let parts =
    run_smooth ~chunking:Ai_core.Smooth_stream.Segmenter
      [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "\228\189\160\229\165\189\228\184\150\231\149\140" } ]
    (* 你好世界 = "Hello world" in Chinese, 4 characters *)
  in
  let texts = text_deltas parts in
  (check int) "one segment per character" 4 (List.length texts);
  let joined = String.concat "" texts in
  (check string) "text preserved" "\228\189\160\229\165\189\228\184\150\231\149\140" joined

let test_segmenter_cjk_japanese () =
  (* Japanese: 東京は美しい — each character is a separate segment *)
  let input = "\230\157\177\228\186\172\227\129\175\231\190\142\227\129\151\227\129\132" in
  let parts =
    run_smooth ~chunking:Ai_core.Smooth_stream.Segmenter
      [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = input } ]
  in
  let texts = text_deltas parts in
  (check int) "one segment per character" 6 (List.length texts);
  let joined = String.concat "" texts in
  (check string) "text preserved" input joined

let test_segmenter_mixed_script () =
  (* Mixed English + CJK: "Hello 世界!" → "Hello" " " "世" "界" "!" *)
  let input = "Hello \228\184\150\231\149\140!" in
  let parts =
    run_smooth ~chunking:Ai_core.Smooth_stream.Segmenter
      [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = input } ]
  in
  let texts = text_deltas parts in
  (check (list string)) "mixed script segments" [ "Hello"; " "; "\228\184\150"; "\231\149\140"; "!" ] texts

let test_segmenter_punctuation () =
  (* Contractions stay together, punctuation separates: "it's" " " "a" " " "test" "." *)
  let parts =
    run_smooth ~chunking:Ai_core.Smooth_stream.Segmenter
      [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "it's a test." } ]
  in
  let texts = text_deltas parts in
  (check (list string)) "punctuation segments" [ "it's"; " "; "a"; " "; "test"; "." ] texts

let test_segmenter_incremental () =
  (* Incremental delivery: segments detected as data arrives *)
  let parts =
    run_smooth ~chunking:Ai_core.Smooth_stream.Segmenter
      [
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "Hel" };
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "lo " };
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "world" };
      ]
  in
  let texts = text_deltas parts in
  let joined = String.concat "" texts in
  (check string) "all text preserved" "Hello world" joined

(* --- Custom chunking --- *)

let test_custom_chunking () =
  let chunker buf =
    match String.length buf >= 3 with
    | true -> Some (String.sub buf 0 3)
    | false -> None
  in
  let parts =
    run_smooth ~chunking:(Ai_core.Smooth_stream.Custom chunker)
      [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "abcdefgh" } ]
  in
  let texts = text_deltas parts in
  (check (list string)) "3-char chunks" [ "abc"; "def"; "gh" ] texts

(* --- Reasoning deltas --- *)

let test_reasoning_smoothing () =
  let parts =
    run_smooth
      [
        Ai_core.Text_stream_part.Reasoning_delta { id = "r1"; text = "thinking step " };
        Ai_core.Text_stream_part.Reasoning_delta { id = "r1"; text = "by step " };
      ]
  in
  let reasons = reasoning_deltas parts in
  (check (list string)) "reasoning words" [ "thinking "; "step "; "by "; "step " ] reasons

(* --- Type/ID switching --- *)

let test_type_switch_flushes () =
  let parts =
    run_smooth
      [
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "partial" };
        Ai_core.Text_stream_part.Reasoning_delta { id = "r1"; text = "think " };
      ]
  in
  let texts = text_deltas parts in
  let reasons = reasoning_deltas parts in
  (check (list string)) "text flushed" [ "partial" ] texts;
  (check (list string)) "reasoning emitted" [ "think " ] reasons

let test_id_switch_flushes () =
  let parts =
    run_smooth
      [
        Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "first" };
        Ai_core.Text_stream_part.Text_delta { id = "t2"; text = "second " };
      ]
  in
  let texts = text_deltas parts in
  (check (list string)) "id switch flushes" [ "first"; "second " ] texts

(* --- Delay --- *)

let test_delay_is_applied () =
  let delays = ref [] in
  let sleep secs =
    delays := secs :: !delays;
    Lwt.return_unit
  in
  let input_stream, push = Lwt_stream.create () in
  push (Some (Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "a b c d " }));
  push None;
  let output = Ai_core.Smooth_stream.create ~delay_ms:20 ~sleep () input_stream in
  let _parts = Lwt_main.run (Lwt_stream.to_list output) in
  (* 4 word chunks, each with 20ms delay *)
  (check (list (float 0.001))) "delay values" [ 0.020; 0.020; 0.020; 0.020 ] (List.rev !delays)

(* --- Text content preservation --- *)

let test_all_text_preserved () =
  let input = "The quick brown fox jumps over the lazy dog" in
  let parts = run_smooth [ Ai_core.Text_stream_part.Text_delta { id = "t1"; text = input } ] in
  let joined = String.concat "" (text_deltas parts) in
  (check string) "text preserved" input joined

let () =
  run "Smooth_stream"
    [
      ( "word",
        [
          test_case "basic" `Quick test_word_chunking_basic;
          test_case "incremental" `Quick test_word_chunking_incremental;
          test_case "passthrough" `Quick test_word_passthrough_non_text;
          test_case "empty" `Quick test_word_empty_input;
          test_case "preserves_text" `Quick test_all_text_preserved;
        ] );
      ( "line",
        [
          test_case "basic" `Quick test_line_chunking;
          test_case "multiple_newlines" `Quick test_line_chunking_multiple_newlines;
        ] );
      "regex", [ test_case "sentence_boundary" `Quick test_regex_chunking ];
      ( "segmenter",
        [
          test_case "english" `Quick test_segmenter_english;
          test_case "cjk_chinese" `Quick test_segmenter_cjk_chinese;
          test_case "cjk_japanese" `Quick test_segmenter_cjk_japanese;
          test_case "mixed_script" `Quick test_segmenter_mixed_script;
          test_case "punctuation" `Quick test_segmenter_punctuation;
          test_case "incremental" `Quick test_segmenter_incremental;
        ] );
      "custom", [ test_case "fixed_size" `Quick test_custom_chunking ];
      ( "reasoning",
        [
          test_case "smoothing" `Quick test_reasoning_smoothing;
          test_case "type_switch_flushes" `Quick test_type_switch_flushes;
          test_case "id_switch_flushes" `Quick test_id_switch_flushes;
        ] );
      "delay", [ test_case "applied" `Quick test_delay_is_applied ];
    ]
