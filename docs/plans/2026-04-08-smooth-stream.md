# Smooth Stream Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement `smooth_stream` — a stream transformer that buffers `Text_delta` and `Reasoning_delta` chunks and re-emits them in word/line/custom-sized pieces with configurable inter-chunk delays, matching the upstream AI SDK's `smoothStream`.

**Architecture:** New `Smooth_stream` module in `ai_core` that produces a `Text_stream_part.t Lwt_stream.t -> Text_stream_part.t Lwt_stream.t` transformer. Five chunking modes: `Word` (regex `\S+\s+`), `Line` (regex `\n+`), `Regex` (user-supplied Re2 pattern), `Segmenter` (Unicode UAX#29 word segmentation via `uuseg`), and `Custom` (user function). A configurable delay (default 10ms) is inserted between emitted chunks via `Lwt_unix.sleep`. Non-smoothable events flush the buffer and pass through unchanged.

**Tech Stack:** Re2 for regex chunking, uuseg for Unicode word segmentation, Lwt for async delays, Alcotest for tests.

---

## Prerequisites

### Step 1: Add dependencies to dune-project

In `dune-project`, add `re2` and `uuseg` to the `ocaml-ai-sdk` package depends:

```
  (re2
   (>= 0.16))
  (uuseg
   (>= 17.0))
```

### Step 2: Add libraries to lib/ai_core/dune

Add `re2` and `uuseg.string` to the `libraries` stanza in `lib/ai_core/dune`:

```
 (libraries
  ai_provider
  lwt
  lwt.unix
  cohttp-lwt-unix
  yojson
  jsonschema
  melange-json-native
  re2
  uuseg.string)
```

### Step 3: Add re2, uuseg.string to test/ai_core/dune

Add `re2` and `uuseg.string` to the test dune `libraries` stanza so tests can construct `Re2.t` values and `Segmenter` chunking:

```
 (libraries
  ai_provider
  ai_provider_anthropic
  ai_core
  alcotest
  lwt
  lwt.unix
  yojson
  melange-json-native
  cohttp
  cohttp-lwt
  cohttp-lwt-unix
  re2
  uuseg.string)
```

### Step 4: Verify build

Run: `opam exec -- dune build`
Expected: Clean build, no errors.

### Step 5: Commit

```
feat: add re2 and uuseg dependencies for smooth_stream
```

---

## Task 1: Smooth_stream module — interface and chunk detection

### Files:
- Create: `lib/ai_core/smooth_stream.mli`
- Create: `lib/ai_core/smooth_stream.ml`
- Modify: `lib/ai_core/ai_core.ml` — add `module Smooth_stream = Smooth_stream`
- Modify: `lib/ai_core/ai_core.mli` — add `module Smooth_stream = Smooth_stream`

### Step 1: Write the .mli

Create `lib/ai_core/smooth_stream.mli`:

```ocaml
(** Smooth text and reasoning streaming output.

    Buffers [Text_delta] and [Reasoning_delta] chunks and re-emits them
    in controlled pieces (word-by-word, line-by-line, or custom) with
    optional inter-chunk delays. Matches the upstream AI SDK's
    [smoothStream] transform.

    All other stream events are passed through immediately, flushing
    any buffered text first. *)

(** How to split buffered text into chunks for emission. *)
type chunking =
  | Word
      (** Stream word-by-word. Matches non-whitespace followed by whitespace
          (regex [\S+\s+]). Default. *)
  | Line
      (** Stream line-by-line. Matches one or more newlines (regex [\n+]). *)
  | Regex of Re2.t
      (** Stream using a custom Re2 pattern. The match (including everything
          before it) is emitted as one chunk — same semantics as upstream
          [RegExp] chunking. *)
  | Segmenter
      (** Unicode UAX#29 word segmentation via [uuseg]. Recommended for
          CJK languages where words are not separated by spaces.
          Equivalent to upstream [Intl.Segmenter]. *)
  | Custom of (string -> string option)
      (** User-provided chunk detector. Receives the buffer, returns the
          prefix to emit as [Some chunk], or [None] to wait for more data.
          The returned string must be a non-empty prefix of the buffer. *)

(** [create ?delay_ms ?chunking ()] returns a stream transformer.

    @param delay_ms Delay in milliseconds between emitted chunks.
      Default is [10]. Pass [0] to disable delays.
    @param chunking Controls how text is split into chunks.
      Default is [Word]. *)
val create :
  ?delay_ms:int ->
  ?chunking:chunking ->
  unit ->
  Text_stream_part.t Lwt_stream.t ->
  Text_stream_part.t Lwt_stream.t
```

### Step 2: Write the .ml — chunk detection helpers

Create `lib/ai_core/smooth_stream.ml`:

```ocaml
type chunking =
  | Word
  | Line
  | Regex of Re2.t
  | Segmenter
  | Custom of (string -> string option)

let word_re = Re2.create_exn {|\S+\s+|}
let line_re = Re2.create_exn {|\n+|}

(** Detect the first chunk in [buffer] using a Re2 regex.
    Returns everything up to and including the match. *)
let detect_chunk_re2 re buffer =
  match Re2.first_match re buffer with
  | Ok m ->
    let pos, len = Re2.Match.get_pos_exn ~sub:(`Index 0) m in
    Some (String.sub buffer 0 (pos + len))
  | Error _ -> None

(** Detect the first word segment using Unicode UAX#29 segmentation. *)
let detect_chunk_segmenter buffer =
  match String.length buffer with
  | 0 -> None
  | _ ->
    let first_segment = ref None in
    (try
       Uuseg_string.fold_utf_8 `Word
         (fun () seg ->
           first_segment := Some seg;
           raise Exit)
         () buffer
     with Exit -> ());
    !first_segment

let make_detector = function
  | Word -> detect_chunk_re2 word_re
  | Line -> detect_chunk_re2 line_re
  | Regex re -> detect_chunk_re2 re
  | Segmenter -> detect_chunk_segmenter
  | Custom f -> f

let create ?(delay_ms = 10) ?(chunking = Word) () input_stream =
  let detect_chunk = make_detector chunking in
  let delay () =
    match delay_ms with
    | 0 -> Lwt.return_unit
    | ms -> Lwt_unix.sleep (Float.of_int ms /. 1000.0)
  in
  let output_stream, push = Lwt_stream.create () in
  let buffer = Buffer.create 256 in
  let current_type = ref None in (* "text" or "reasoning" *)
  let current_id = ref "" in
  let flush_buffer () =
    let buf_contents = Buffer.contents buffer in
    match String.length buf_contents, !current_type with
    | 0, _ | _, None -> ()
    | _, Some `Text ->
      push (Some (Text_stream_part.Text_delta { id = !current_id; text = buf_contents }));
      Buffer.clear buffer
    | _, Some `Reasoning ->
      push (Some (Text_stream_part.Reasoning_delta { id = !current_id; text = buf_contents }));
      Buffer.clear buffer
  in
  let emit_chunk chunk =
    match !current_type with
    | Some `Text -> push (Some (Text_stream_part.Text_delta { id = !current_id; text = chunk }))
    | Some `Reasoning -> push (Some (Text_stream_part.Reasoning_delta { id = !current_id; text = chunk }))
    | None -> ()
  in
  Lwt.async (fun () ->
    let%lwt () =
      Lwt_stream.iter_s
        (fun (part : Text_stream_part.t) ->
          match part with
          | Text_delta { id; text } ->
            (* Flush if type or id changed *)
            (match !current_type with
            | Some `Text when String.equal !current_id id -> ()
            | _ ->
              flush_buffer ();
              current_type := Some `Text;
              current_id := id);
            Buffer.add_string buffer text;
            (* Emit detected chunks *)
            let rec drain () =
              match detect_chunk (Buffer.contents buffer) with
              | None -> Lwt.return_unit
              | Some chunk ->
                emit_chunk chunk;
                let chunk_len = String.length chunk in
                let remaining = Buffer.contents buffer in
                Buffer.clear buffer;
                Buffer.add_string buffer (String.sub remaining chunk_len (String.length remaining - chunk_len));
                let%lwt () = delay () in
                drain ()
            in
            drain ()
          | Reasoning_delta { id; text } ->
            (match !current_type with
            | Some `Reasoning when String.equal !current_id id -> ()
            | _ ->
              flush_buffer ();
              current_type := Some `Reasoning;
              current_id := id);
            Buffer.add_string buffer text;
            let rec drain () =
              match detect_chunk (Buffer.contents buffer) with
              | None -> Lwt.return_unit
              | Some chunk ->
                emit_chunk chunk;
                let chunk_len = String.length chunk in
                let remaining = Buffer.contents buffer in
                Buffer.clear buffer;
                Buffer.add_string buffer (String.sub remaining chunk_len (String.length remaining - chunk_len));
                let%lwt () = delay () in
                drain ()
            in
            drain ()
          | other ->
            flush_buffer ();
            current_type := None;
            push (Some other);
            Lwt.return_unit)
        input_stream
    in
    (* Flush remaining buffer at end of stream *)
    flush_buffer ();
    push None;
    Lwt.return_unit);
  output_stream
```

**Refactoring note:** The `Text_delta` and `Reasoning_delta` branches are nearly identical. Factor the drain logic into a shared helper `process_smoothable` to avoid the duplication:

```ocaml
let process_smoothable ~buffer ~current_type ~current_id ~detect_chunk ~emit_chunk ~delay ~new_type ~id ~text =
  (match !current_type with
  | Some t when t = new_type && String.equal !current_id id -> ()
  | _ ->
    flush_buffer ();
    current_type := Some new_type;
    current_id := id);
  Buffer.add_string buffer text;
  let rec drain () =
    match detect_chunk (Buffer.contents buffer) with
    | None -> Lwt.return_unit
    | Some chunk ->
      emit_chunk chunk;
      let chunk_len = String.length chunk in
      let remaining = Buffer.contents buffer in
      Buffer.clear buffer;
      Buffer.add_string buffer (String.sub remaining chunk_len (String.length remaining - chunk_len));
      let%lwt () = delay () in
      drain ()
  in
  drain ()
```

Then match:

```ocaml
| Text_delta { id; text } ->
  process_smoothable ... ~new_type:`Text ~id ~text
| Reasoning_delta { id; text } ->
  process_smoothable ... ~new_type:`Reasoning ~id ~text
```

### Step 3: Export from ai_core

Add `module Smooth_stream = Smooth_stream` to both `lib/ai_core/ai_core.ml` and `lib/ai_core/ai_core.mli`.

### Step 4: Verify build

Run: `opam exec -- dune build`
Expected: Clean build.

### Step 5: Commit

```
feat: add Smooth_stream module with chunk detection and stream transform
```

---

## Task 2: Tests — Word chunking

### Files:
- Create: `test/ai_core/test_smooth_stream.ml`
- Modify: `test/ai_core/dune` — add `test_smooth_stream` to `names`

### Step 1: Write tests

Create `test/ai_core/test_smooth_stream.ml` with the following test cases. All tests use `delay_ms:0` to avoid timing dependencies.

```ocaml
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
```

Test cases for word chunking:

```ocaml
let test_word_chunking_basic () =
  (* "Hello world " has a complete word+space, "foo" does not *)
  let parts = run_smooth [
    Text_stream_part.Text_delta { id = "t1"; text = "Hello world foo" }
  ] in
  let texts = text_deltas parts in
  (* "Hello " and "world " are complete word chunks, "foo" is flushed at end *)
  (check (list string)) "word chunks" ["Hello "; "world "; "foo"] texts

let test_word_chunking_incremental () =
  (* Text arrives in small pieces *)
  let parts = run_smooth [
    Text_stream_part.Text_delta { id = "t1"; text = "Hel" };
    Text_stream_part.Text_delta { id = "t1"; text = "lo " };
    Text_stream_part.Text_delta { id = "t1"; text = "wor" };
    Text_stream_part.Text_delta { id = "t1"; text = "ld " };
  ] in
  let texts = text_deltas parts in
  (check (list string)) "incremental words" ["Hello "; "world "] texts

let test_word_passthrough_non_text () =
  (* Non-text events pass through, flushing buffer *)
  let parts = run_smooth [
    Text_stream_part.Text_delta { id = "t1"; text = "Hello " };
    Text_stream_part.Start_step;
    Text_stream_part.Text_delta { id = "t1"; text = "world " };
  ] in
  let has_start_step = List.exists (function
    | Ai_core.Text_stream_part.Start_step -> true
    | _ -> false) parts in
  (check bool) "start_step passes through" true has_start_step;
  let texts = text_deltas parts in
  (check (list string)) "text around event" ["Hello "; "world "] texts

let test_word_empty_input () =
  let parts = run_smooth [] in
  (check int) "empty" 0 (List.length parts)
```

### Step 2: Add test to dune

Add `test_smooth_stream` to the `names` list in `test/ai_core/dune`.

### Step 3: Run tests

Run: `opam exec -- dune exec test/ai_core/test_smooth_stream.exe`
Expected: All tests pass.

### Step 4: Commit

```
test: add word chunking tests for Smooth_stream
```

---

## Task 3: Tests — Line chunking

### Step 1: Add line chunking tests

```ocaml
let test_line_chunking () =
  let parts = run_smooth ~chunking:Ai_core.Smooth_stream.Line [
    Text_stream_part.Text_delta { id = "t1"; text = "line one\nline two\nthree" }
  ] in
  let texts = text_deltas parts in
  (check (list string)) "line chunks" ["line one\n"; "line two\n"; "three"] texts

let test_line_chunking_multiple_newlines () =
  let parts = run_smooth ~chunking:Ai_core.Smooth_stream.Line [
    Text_stream_part.Text_delta { id = "t1"; text = "a\n\nb" }
  ] in
  let texts = text_deltas parts in
  (check (list string)) "double newline" ["a\n\n"; "b"] texts
```

### Step 2: Run and verify

Run: `opam exec -- dune exec test/ai_core/test_smooth_stream.exe`
Expected: All pass.

### Step 3: Commit

```
test: add line chunking tests for Smooth_stream
```

---

## Task 4: Tests — Regex, Segmenter, Custom chunking

### Step 1: Add regex chunking test

```ocaml
let test_regex_chunking () =
  (* Chunk on sentence boundaries: period followed by space *)
  let re = Re2.create_exn {|\.\s+|} in
  let parts = run_smooth ~chunking:(Ai_core.Smooth_stream.Regex re) [
    Text_stream_part.Text_delta { id = "t1"; text = "Hello. World. End" }
  ] in
  let texts = text_deltas parts in
  (check (list string)) "sentence chunks" ["Hello. "; "World. "; "End"] texts
```

### Step 2: Add segmenter test

```ocaml
let test_segmenter_chunking () =
  (* Segmenter should split on Unicode word boundaries *)
  let parts = run_smooth ~chunking:Ai_core.Smooth_stream.Segmenter [
    Text_stream_part.Text_delta { id = "t1"; text = "Hello world" }
  ] in
  let texts = text_deltas parts in
  (* uuseg word segmenter includes inter-word spaces as separate segments *)
  (check int) "has segments" true (List.length texts > 1)
```

Note: The exact segmentation output depends on uuseg's UAX#29 implementation. The test should verify segmentation happens (multiple chunks) rather than asserting exact output, since UAX#29 word boundaries are complex. Adjust assertions after running to match actual uuseg output.

### Step 3: Add custom chunking test

```ocaml
let test_custom_chunking () =
  (* Custom: emit exactly 3 characters at a time *)
  let chunker buf =
    if String.length buf >= 3 then Some (String.sub buf 0 3)
    else None
  in
  let parts = run_smooth ~chunking:(Ai_core.Smooth_stream.Custom chunker) [
    Text_stream_part.Text_delta { id = "t1"; text = "abcdefgh" }
  ] in
  let texts = text_deltas parts in
  (* "abc", "def" detected, "gh" flushed at end *)
  (check (list string)) "3-char chunks" ["abc"; "def"; "gh"] texts
```

### Step 4: Run and verify

Run: `opam exec -- dune exec test/ai_core/test_smooth_stream.exe`
Expected: All pass.

### Step 5: Commit

```
test: add regex, segmenter, and custom chunking tests
```

---

## Task 5: Tests — Reasoning deltas, id/type switching, delay

### Step 1: Add reasoning delta test

```ocaml
let test_reasoning_smoothing () =
  let parts = run_smooth [
    Text_stream_part.Reasoning_delta { id = "r1"; text = "thinking step " };
    Text_stream_part.Reasoning_delta { id = "r1"; text = "by step " };
  ] in
  let reasons = reasoning_deltas parts in
  (check (list string)) "reasoning words" ["thinking "; "step "; "by "; "step "] reasons
```

### Step 2: Add type/id switch test

```ocaml
let test_type_switch_flushes () =
  (* Switching from text to reasoning should flush the text buffer *)
  let parts = run_smooth [
    Text_stream_part.Text_delta { id = "t1"; text = "partial" };
    Text_stream_part.Reasoning_delta { id = "r1"; text = "think " };
  ] in
  let texts = text_deltas parts in
  let reasons = reasoning_deltas parts in
  (* "partial" flushed when reasoning starts *)
  (check (list string)) "text flushed" ["partial"] texts;
  (check (list string)) "reasoning emitted" ["think "] reasons

let test_id_switch_flushes () =
  (* Same type but different id should flush *)
  let parts = run_smooth [
    Text_stream_part.Text_delta { id = "t1"; text = "first" };
    Text_stream_part.Text_delta { id = "t2"; text = "second " };
  ] in
  let texts = text_deltas parts in
  (check (list string)) "id switch flushes" ["first"; "second "] texts
```

### Step 3: Add delay test

```ocaml
let test_delay_is_applied () =
  (* Verify delay is actually applied by measuring elapsed time *)
  let input_stream, push = Lwt_stream.create () in
  push (Some (Ai_core.Text_stream_part.Text_delta { id = "t1"; text = "a b c d " }));
  push None;
  let output = Ai_core.Smooth_stream.create ~delay_ms:20 () input_stream in
  let t0 = Unix.gettimeofday () in
  let _parts = Lwt_main.run (Lwt_stream.to_list output) in
  let elapsed = Unix.gettimeofday () -. t0 in
  (* 4 word chunks with 20ms delay each = ~80ms minimum *)
  (check bool) "delay applied" true (elapsed >= 0.05)
```

### Step 4: Run and verify

Run: `opam exec -- dune exec test/ai_core/test_smooth_stream.exe`
Expected: All pass.

### Step 5: Commit

```
test: add reasoning, type switching, and delay tests for Smooth_stream
```

---

## Task 6: Wire into stream_text

### Files:
- Modify: `lib/ai_core/stream_text.ml` — apply transform to full_stream
- Modify: `lib/ai_core/stream_text.mli` — add `?transform` parameter

### Step 1: Add `?transform` parameter

Add to both `stream_text.mli` and `stream_text.ml`:

```ocaml
?transform:(Text_stream_part.t Lwt_stream.t -> Text_stream_part.t Lwt_stream.t) ->
```

This goes after `?on_finish` and before `?pending_tool_approvals`. The parameter is a generic stream transformer, not tied to `smooth_stream` specifically — matching upstream's `experimental_transform` which accepts any `TransformStream`.

### Step 2: Apply transform in stream_text.ml

In the `stream_text` function, after creating `full_stream`, apply the transform if present:

```ocaml
let full_stream =
  match transform with
  | Some f -> f full_stream
  | None -> full_stream
in
```

The transform is applied to the `full_stream` that the caller consumes. The internal `push_full` still writes to the raw stream — the transform sits between the raw events and the consumer.

**Important:** The `text_stream` (string-only stream) must also reflect the transformed output. To do this, derive `text_stream` from the transformed `full_stream` rather than pushing to it directly.

### Step 3: Also expose on server_handler

Modify `server_handler.ml` and `server_handler.mli` to accept and forward `?transform`.

### Step 4: Run all tests

Run: `opam exec -- dune runtest`
Expected: All existing tests still pass.

### Step 5: Commit

```
feat: add ?transform parameter to stream_text for smooth streaming
```

---

## Task 7: Integration test — smooth_stream with stream_text

### Step 1: Add integration test in test_stream_text.ml

```ocaml
let test_stream_smooth_stream () =
  let model = make_stream_model () in
  let transform = Ai_core.Smooth_stream.create ~delay_ms:0 () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Hello"
      ~transform ()
  in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* The smoothed stream should still contain all text content *)
  let all_text =
    List.filter_map
      (function
      | Ai_core.Text_stream_part.Text_delta { text; _ } -> Some text
      | _ -> None)
      parts
    |> String.concat ""
  in
  (check bool) "has text" true (String.length all_text > 0)
```

### Step 2: Run and verify

Run: `opam exec -- dune exec test/ai_core/test_stream_text.exe`
Expected: Pass.

### Step 3: Commit

```
test: add smooth_stream integration test with stream_text
```

---

## Task 8: Format and final verification

### Step 1: Format all files

Run: `opam exec -- dune build @fmt --auto-promote`

### Step 2: Run full test suite

Run: `opam exec -- dune runtest`
Expected: All tests pass, no regressions.

### Step 3: Commit

```
chore: format smooth_stream files
```
