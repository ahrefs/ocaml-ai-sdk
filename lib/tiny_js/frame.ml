let default_max_frame_bytes = 16_777_216
let max_allowed_frame_bytes = 1 lsl 30

type write_error =
  | Too_large of {
      size : int;
      max : int;
    }
  | Empty
  | Io_error of string

let string_of_write_error = function
  | Too_large { size; max } -> Printf.sprintf "frame of %d bytes exceeds the %d byte limit" size max
  | Empty -> "empty frames are not allowed"
  | Io_error msg -> Printf.sprintf "I/O error: %s" msg

let io_error_message = function
  | Unix.Unix_error (e, fn, _) -> Some (Printf.sprintf "%s: %s" fn (Unix.error_message e))
  | Lwt_io.Channel_closed what -> Some (Printf.sprintf "channel closed (%s)" what)
  | Sys_error msg -> Some msg
  | End_of_file -> Some "end of file"
  | _ -> None

let write ~max_frame_bytes oc payload =
  let size = String.length payload in
  match size with
  | 0 -> Lwt.return (Error Empty)
  | size when size > max_frame_bytes -> Lwt.return (Error (Too_large { size; max = max_frame_bytes }))
  | size ->
    let header = Bytes.create 4 in
    Bytes.set_int32_le header 0 (Int32.of_int size);
    (try%lwt
       let%lwt () =
         Lwt_io.atomic
           (fun oc ->
             let%lwt () = Lwt_io.write_from_exactly oc header 0 4 in
             Lwt_io.write oc payload)
           oc
       in
       let%lwt () = Lwt_io.flush oc in
       Lwt.return (Ok ())
     with exn ->
       (match io_error_message exn with
       | Some msg -> Lwt.return (Error (Io_error msg))
       | None -> Lwt.reraise exn))

(* [Ok true] when [len] bytes were read, [Ok false] on EOF before the first byte, [Error] on EOF later. *)
let read_exactly ic buf ~len ~what =
  let%lwt first = Lwt_io.read_into ic buf 0 len in
  match first with
  | 0 -> Lwt.return (Ok false)
  | n when n = len -> Lwt.return (Ok true)
  | n ->
  try%lwt
    let%lwt () = Lwt_io.read_into_exactly ic buf n (len - n) in
    Lwt.return (Ok true)
  with End_of_file -> Lwt.return (Error (Printf.sprintf "end of file inside %s" what))

(* The payload grows as bytes actually arrive, in bounded chunks: a header that claims [size] bytes
   costs no more memory than what the peer really sends. *)
let chunk_size = 65_536

let read_payload ic ~size =
  let buffer = Buffer.create (min size chunk_size) in
  let chunk = Bytes.create (min size chunk_size) in
  let rec loop remaining =
    match remaining with
    | 0 -> Lwt.return (Ok (Buffer.contents buffer))
    | remaining ->
      let%lwt n = Lwt_io.read_into ic chunk 0 (min remaining chunk_size) in
      (match n with
      | 0 -> Lwt.return (Error "end of file inside a frame payload")
      | n ->
        Buffer.add_subbytes buffer chunk 0 n;
        loop (remaining - n))
  in
  loop size

let read ~max_frame_bytes ic =
  try%lwt
    let header = Bytes.create 4 in
    match%lwt read_exactly ic header ~len:4 ~what:"a length prefix" with
    | Error _ as e -> Lwt.return e
    | Ok false -> Lwt.return (Ok None)
    | Ok true ->
      let size = Int32.to_int (Bytes.get_int32_le header 0) land 0xFFFF_FFFF in
      (match size with
      | 0 -> Lwt.return (Error "zero-length frame")
      | size when size > max_frame_bytes ->
        Lwt.return (Error (Printf.sprintf "frame length %d exceeds the %d byte limit" size max_frame_bytes))
      | size ->
      match%lwt read_payload ic ~size with
      | Ok payload -> Lwt.return (Ok (Some payload))
      | Error _ as e -> Lwt.return e)
  with exn ->
    (match io_error_message exn with
    | Some msg -> Lwt.return (Error (Printf.sprintf "I/O error: %s" msg))
    | None -> Lwt.reraise exn)
