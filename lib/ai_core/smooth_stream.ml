type chunking =
  | Word
  | Line
  | Regex of Re2.t
  | Segmenter
  | Custom of (string -> string option)

type active =
  | Active_text of string
  | Active_reasoning of string

let word_re = Re2.create_exn {|\S+\s+|}
let line_re = Re2.create_exn {|\n+|}

let detect_chunk_re2 re buffer =
  match Re2.first_match re buffer with
  | Ok m ->
    let pos, len = Re2.Match.get_pos_exn ~sub:(`Index 0) m in
    Some (String.sub buffer 0 (pos + len))
  | Error _ -> None

let detect_chunk_segmenter buffer =
  if String.length buffer = 0 then None
  else (
    let first = ref None in
    (try
       Uuseg_string.fold_utf_8 `Word
         (fun () seg ->
           if String.length seg > 0 then (
             first := Some seg;
             raise_notrace Exit))
         () buffer
     with Exit -> ());
    !first)

let make_detector = function
  | Word -> detect_chunk_re2 word_re
  | Line -> detect_chunk_re2 line_re
  | Regex re -> detect_chunk_re2 re
  | Segmenter -> detect_chunk_segmenter
  | Custom f -> f

let create ?(delay_ms = 10) ?(chunking = Word) () input_stream =
  let detect_chunk = make_detector chunking in
  let delay =
    match delay_ms with
    | 0 -> fun () -> Lwt.return_unit
    | ms ->
      let secs = Float.of_int ms /. 1000.0 in
      fun () -> Lwt_unix.sleep secs
  in
  let output_stream, push = Lwt_stream.create () in
  let buffer = Buffer.create 256 in
  let current : active option ref = ref None in
  let emit_delta active text =
    match active with
    | Active_text id -> push (Some (Text_stream_part.Text_delta { id; text }))
    | Active_reasoning id -> push (Some (Text_stream_part.Reasoning_delta { id; text }))
  in
  let flush_buffer () =
    if Buffer.length buffer > 0 then (
      match !current with
      | None -> ()
      | Some active ->
        emit_delta active (Buffer.contents buffer);
        Buffer.clear buffer)
  in
  let process_smoothable ~active ~text =
    let same =
      match !current, active with
      | Some (Active_text a), Active_text b -> String.equal a b
      | Some (Active_reasoning a), Active_reasoning b -> String.equal a b
      | Some (Active_text _), Active_reasoning _
      | Some (Active_reasoning _), Active_text _
      | None, (Active_text _ | Active_reasoning _) ->
        false
    in
    if not same then (
      flush_buffer ();
      current := Some active);
    Buffer.add_string buffer text;
    let rec drain () =
      match detect_chunk (Buffer.contents buffer) with
      | None -> Lwt.return_unit
      | Some chunk ->
        emit_delta active chunk;
        let chunk_len = String.length chunk in
        let remaining = Buffer.contents buffer in
        Buffer.clear buffer;
        Buffer.add_string buffer (String.sub remaining chunk_len (String.length remaining - chunk_len));
        let%lwt () = delay () in
        drain ()
    in
    drain ()
  in
  Lwt.async (fun () ->
    try%lwt
      let%lwt () =
        Lwt_stream.iter_s
          (fun (part : Text_stream_part.t) ->
            match part with
            | Text_delta { id; text } -> process_smoothable ~active:(Active_text id) ~text
            | Reasoning_delta { id; text } -> process_smoothable ~active:(Active_reasoning id) ~text
            | other ->
              flush_buffer ();
              current := None;
              push (Some other);
              Lwt.return_unit)
          input_stream
      in
      flush_buffer ();
      push None;
      Lwt.return_unit
    with exn ->
      push (Some (Text_stream_part.Error { error = Printexc.to_string exn }));
      push None;
      Lwt.return_unit);
  output_stream
