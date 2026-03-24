type event = {
  event_type : string;
  data : string;
}

let parse_events lines =
  let current_event = ref "" in
  let current_data = Buffer.create 256 in
  let stream, push = Lwt_stream.create () in
  let emit () =
    if String.length !current_event > 0 || Buffer.length current_data > 0 then begin
      let evt = { event_type = !current_event; data = Buffer.contents current_data } in
      push (Some evt);
      current_event := "";
      Buffer.clear current_data
    end
  in
  Lwt.async (fun () ->
    let%lwt () =
      Lwt_stream.iter
        (fun line ->
          match line with
          | "" -> emit ()
          | line when String.starts_with ~prefix:":" line -> ()
          | line when String.starts_with ~prefix:"event:" line ->
            let value = String.trim (String.sub line 6 (String.length line - 6)) in
            current_event := value
          | line when String.starts_with ~prefix:"data:" line ->
            let value = String.sub line 5 (String.length line - 5) in
            let value =
              if String.length value > 0 && Char.equal (String.get value 0) ' ' then
                String.sub value 1 (String.length value - 1)
              else value
            in
            if Buffer.length current_data > 0 then Buffer.add_char current_data '\n';
            Buffer.add_string current_data value
          | _ -> ())
        lines
    in
    emit ();
    push None;
    Lwt.return_unit);
  stream
