open Alcotest

let run_lwt f () = Lwt_main.run (f ())

let event data = { Ai_provider.Sse.event_type = "message"; data }

(* Pumps [events] through [f], which pushes a [Text] part per event, and
   collects what reaches the output. *)
let pumped f events =
  let output, push = Lwt_stream.create () in
  Ai_provider.Stream_part.pump ~provider:"test" ~push
    (fun evt -> push (Some (Ai_provider.Stream_part.Text { text = f evt })))
    (Lwt_stream.of_list events);
  Lwt_stream.to_list output

let describe = function
  | Ai_provider.Stream_part.Text { text } -> "text " ^ text
  | Error { error = { kind = Deserialization_error { raw; _ }; is_retryable; _ } } ->
    Printf.sprintf "deserialization raw=%S retryable=%b" raw is_retryable
  | _ -> "other"

let decode (evt : Ai_provider.Sse.event) =
  match Yojson.Basic.from_string evt.data with
  | `String text -> text
  | json -> Yojson.Basic.to_string json

(* A malformed event is reported with its data and the next event still runs. *)
let test_malformed_event_skipped () =
  let%lwt parts = pumped decode [ event {|"a"|}; event "{not json"; event {|"b"|} ] in
  (check (list string))
    "parts"
    [ "text a"; {|deserialization raw="{not json" retryable=false|}; "text b" ]
    (List.map describe parts);
  Lwt.return_unit

(* Any other exception from the converter ends the stream with an error part
   instead of reaching Lwt's async exception hook. *)
let test_unexpected_exception_ends_stream () =
  let f (evt : Ai_provider.Sse.event) =
    match evt.data with
    | "boom" -> raise Not_found
    | data -> data
  in
  let%lwt parts = pumped f [ event "a"; event "boom"; event "b" ] in
  (check (list string)) "parts" [ "text a"; {|deserialization raw="" retryable=false|} ] (List.map describe parts);
  Lwt.return_unit

let () =
  run "Stream_part"
    [
      ( "pump",
        [
          test_case "malformed event skipped" `Quick (run_lwt test_malformed_event_skipped);
          test_case "unexpected exception ends stream" `Quick (run_lwt test_unexpected_exception_ends_stream);
        ] );
    ]
