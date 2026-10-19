type event = {
  event_type : string;
  data : string;
}

let parse_events lines =
  let current_event = ref "" in
  let current_data = Buffer.create 256 in
  let reset () =
    current_event := "";
    Buffer.clear current_data
  in
  let take_event () =
    if String.length !current_event > 0 || Buffer.length current_data > 0 then begin
      let evt = { event_type = !current_event; data = Buffer.contents current_data } in
      reset ();
      Some evt
    end
    else None
  in
  let add_line = function
    | line when String.starts_with ~prefix:":" line -> ()
    | line when String.starts_with ~prefix:"event:" line ->
      current_event := String.trim (String.sub line 6 (String.length line - 6))
    | line when String.starts_with ~prefix:"data:" line ->
      let value = String.sub line 5 (String.length line - 5) in
      let value =
        if String.length value > 0 && Char.equal (String.get value 0) ' ' then
          String.sub value 1 (String.length value - 1)
        else value
      in
      if Buffer.length current_data > 0 then Buffer.add_char current_data '\n';
      Buffer.add_string current_data value
    | _ -> ()
  in
  let rec next_event () =
    match%lwt Lwt_stream.get lines with
    | None -> Lwt.return (take_event ())
    | Some "" ->
      (match take_event () with
      | Some _ as evt -> Lwt.return evt
      | None -> next_event ())
    | Some line ->
      add_line line;
      next_event ()
    | exception exn ->
      reset ();
      Lwt.fail exn
  in
  Lwt_stream.from next_event
