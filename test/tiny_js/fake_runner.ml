(* Scripted runner speaking the tiny-js-sandbox protocol, for testing [Tiny_js.Vm].

   Startup behaviour is selected by the value of [--memory-limit-mb]:
   1 = hello with proto 2, 2 = exit without hello, anything else = normal hello.

   Each [eval] code is a command:
   - text:S / bytes:S : answer with that value; null : answer null; error:S : answer a JS-style error
   - post:S / postbytes:S : send a message frame, then answer null
   - log:LEVEL:TEXT : send a log frame, then answer null
   - args : answer with argv (space separated)
   - die : exit 3 without answering; hang : never answer
   - garbage : write a frame that is not valid CBOR; unknown_id : answer an id nobody asked for
   - huge : write a length prefix of 1 GiB
   - runner_error : send an error frame then exit 4
   Messages from the parent are echoed back (same kind, text prefixed by "echo:"). *)

open Tiny_js

let max_frame_bytes = Frame.default_max_frame_bytes

let send frame =
  match%lwt Frame.write ~max_frame_bytes Lwt_io.stdout (Cbor.encode frame) with
  | Ok () -> Lwt.return_unit
  | Error e -> Printf.ksprintf failwith "fake runner write: %s" (Frame.string_of_write_error e)

let t_map ty fields = Cbor.Map (("t", Cbor.Text ty) :: fields)
let result ~id v = send (t_map "eval_result" [ "id", Cbor.Int id; "ok", Cbor.Bool true; "value", v ])

let cut prefix s =
  match String.starts_with ~prefix s with
  | true -> Some (String.sub s (String.length prefix) (String.length s - String.length prefix))
  | false -> None

let command ~id code =
  let ( >>? ) = Option.bind in
  match code with
  | "null" -> result ~id Cbor.Null
  | "args" -> result ~id (Cbor.Text (String.concat " " (List.tl (Array.to_list Sys.argv))))
  | "die" -> exit 3
  | "hang" -> Lwt.return_unit
  | "garbage" ->
    let%lwt () = Lwt_io.write Lwt_io.stdout "\003\000\000\000\xff\xff\xff" in
    Lwt_io.flush Lwt_io.stdout
  | "unknown_id" -> result ~id:999_999 Cbor.Null
  | "huge" ->
    let%lwt () = Lwt_io.write Lwt_io.stdout "\000\000\000\x40" in
    Lwt_io.flush Lwt_io.stdout
  | "runner_error" ->
    let%lwt () = send (t_map "error" [ "message", Cbor.Text "scripted failure" ]) in
    exit 4
  | code ->
    let handlers =
      [
        (fun () -> cut "text:" code >>? fun s -> Some (result ~id (Cbor.Text s)));
        (fun () -> cut "bytes:" code >>? fun s -> Some (result ~id (Cbor.Bytes s)));
        (fun () ->
          cut "error:" code >>? fun s ->
          Some (send (t_map "eval_result" [ "id", Cbor.Int id; "ok", Cbor.Bool false; "error", Cbor.Text s ])));
        (fun () ->
          cut "post:" code >>? fun s ->
          Some
            (let%lwt () = send (t_map "message" [ "data", Cbor.Text s ]) in
             result ~id Cbor.Null));
        (fun () ->
          cut "postbytes:" code >>? fun s ->
          Some
            (let%lwt () = send (t_map "message" [ "data", Cbor.Bytes s ]) in
             result ~id Cbor.Null));
        (fun () ->
          cut "log:" code >>? fun rest ->
          Option.bind (String.index_opt rest ':') (fun i ->
            let level = String.sub rest 0 i
            and text = String.sub rest (i + 1) (String.length rest - i - 1) in
            Some
              (let%lwt () = send (t_map "log" [ "level", Cbor.Text level; "text", Cbor.Text text ]) in
               result ~id Cbor.Null)));
      ]
    in
    (match List.find_map (fun h -> h ()) handlers with
    | Some p -> p
    | None ->
      send (t_map "eval_result" [ "id", Cbor.Int id; "ok", Cbor.Bool false; "error", Cbor.Text "unknown command" ]))

let handle = function
  | Cbor.Map [ ("t", Cbor.Text "eval"); ("id", Cbor.Int id); ("code", Cbor.Text code) ]
  | Cbor.Map [ ("t", Cbor.Text "eval"); ("code", Cbor.Text code); ("id", Cbor.Int id) ] ->
    command ~id code
  | Cbor.Map [ ("t", Cbor.Text "message"); ("data", Cbor.Text s) ] ->
    send (t_map "message" [ "data", Cbor.Text ("echo:" ^ s) ])
  | Cbor.Map [ ("t", Cbor.Text "message"); ("data", Cbor.Bytes b) ] -> send (t_map "message" [ "data", Cbor.Bytes b ])
  | other ->
    let%lwt () = send (t_map "error" [ "message", Cbor.Text (Format.asprintf "bad frame %a" Cbor.pp other) ]) in
    exit 2

let rec loop () =
  match%lwt Frame.read ~max_frame_bytes Lwt_io.stdin with
  | Ok None -> exit 0
  | Error e ->
    let%lwt () = send (t_map "error" [ "message", Cbor.Text e ]) in
    exit 2
  | Ok (Some payload) ->
  match Cbor.decode payload with
  | Error e ->
    let%lwt () = send (t_map "error" [ "message", Cbor.Text e ]) in
    exit 2
  | Ok frame ->
    let%lwt () = handle frame in
    loop ()

let () =
  let mem =
    let rec find = function
      | "--memory-limit-mb" :: v :: _ -> int_of_string v
      | _ :: rest -> find rest
      | [] -> 0
    in
    find (Array.to_list Sys.argv)
  in
  match mem with
  | 2 -> exit 5
  | mem ->
    Lwt_main.run
      (let%lwt () = send (t_map "hello" [ "proto", Cbor.Int (if mem = 1 then 2 else 1) ]) in
       loop ())
