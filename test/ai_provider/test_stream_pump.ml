open Alcotest

let run_lwt f () = Lwt_main.run (f ())

let event data = { Ai_provider.Sse.event_type = "message"; data }

(* Pumps [events] through [f], which pushes a [Text] part per event, and
   collects what reaches the output. *)
let pumped_stream f events =
  let output, push = Lwt_stream.create () in
  Ai_provider.Stream_pump.pump ~provider:"test" ~push
    (fun evt -> push (Some (Ai_provider.Stream_part.Text { text = f evt })))
    events;
  Lwt_stream.to_list output

let pumped f events = pumped_stream f (Lwt_stream.of_list events)

let describe_kind : Ai_provider.Provider_error.error_kind -> string = function
  | Deserialization_error { raw; _ } -> Printf.sprintf "deserialization raw=%S" raw
  | Unexpected_error { message } -> "unexpected " ^ message
  | Api_error { status; _ } -> Printf.sprintf "api %d" status
  | Network_error { message } -> "network " ^ message
  | Timeout _ -> "timeout"

let describe = function
  | Ai_provider.Stream_part.Text { text } -> "text " ^ text
  | Error { error = { kind; is_retryable; provider; _ } } ->
    Printf.sprintf "%s retryable=%b provider=%s" (describe_kind kind) is_retryable provider
  | Stream_start _ | Reasoning _ | Tool_call_delta _ | Tool_call_finish _ | File _ | Source _ | Finish _ -> "other"

let decode (evt : Ai_provider.Sse.event) =
  match Yojson.Basic.from_string evt.data with
  | `String text -> text
  | json -> Yojson.Basic.to_string json

(* A malformed event is reported with its data and the next event still runs. *)
let test_malformed_event_skipped () =
  let%lwt parts = pumped decode [ event {|"a"|}; event "{not json"; event {|"b"|} ] in
  (check (list string))
    "parts"
    [ "text a"; {|deserialization raw="{not json" retryable=false provider=test|}; "text b" ]
    (List.map describe parts);
  Lwt.return_unit

(* Every JSON decode error, from Yojson or melange-json, is a
   [Deserialization_error] carrying the event's data. *)
let test_decode_errors_carry_raw_data () =
  let decoders =
    [
      ("json", fun () -> raise (Yojson.Json_error "bad"));
      ("end_of_array", fun () -> raise Yojson.End_of_array);
      ("end_of_object", fun () -> raise Yojson.End_of_object);
      ("end_of_input", fun () -> raise Yojson.End_of_input);
      ("basic_type", fun () -> Yojson.Basic.Util.to_string (`Int 1));
      ("basic_undefined", fun () -> raise (Yojson.Basic.Util.Undefined ("missing", `Null)));
      ("safe_type", fun () -> Yojson.Safe.Util.to_string (`Int 1));
      ("safe_undefined", fun () -> raise (Yojson.Safe.Util.Undefined ("missing", `Null)));
      ("of_json", fun () -> raise (Melange_json.Of_json_error (Json_error "expected a string")));
      ("of_string", fun () -> raise (Melange_json.Of_string_error "bad input"));
    ]
  in
  let f (evt : Ai_provider.Sse.event) =
    match List.assoc_opt evt.data decoders with
    | Some decode -> decode ()
    | None -> evt.data
  in
  let names = List.map fst decoders in
  let%lwt parts = pumped f (List.map event (names @ [ "end" ])) in
  (check (list string))
    "parts"
    (List.map (Printf.sprintf "deserialization raw=%S retryable=false provider=test") names @ [ "text end" ])
    (List.map describe parts);
  Lwt.return_unit

(* Any other exception from the converter ends the stream with an
   [Unexpected_error] instead of reaching Lwt's async exception hook. *)
let test_unexpected_exception_ends_stream () =
  let f (evt : Ai_provider.Sse.event) =
    match evt.data with
    | "boom" -> failwith "boom"
    | data -> data
  in
  let%lwt parts = pumped f [ event "a"; event "boom"; event "b" ] in
  (check (list string))
    "parts"
    [ "text a"; {|unexpected Failure("boom") retryable=false provider=test|} ]
    (List.map describe parts);
  Lwt.return_unit

(* A [Provider_error] raised by the converter keeps its own fields and ends
   the stream. *)
let test_converter_provider_error_kept () =
  let error =
    Ai_provider.Provider_error.make_api_error ~provider:"upstream" ~status:429 ~body:"slow down" ~is_retryable:true ()
  in
  let f (evt : Ai_provider.Sse.event) =
    match evt.data with
    | "limit" -> raise (Ai_provider.Provider_error.Provider_error error)
    | data -> data
  in
  let%lwt parts = pumped f [ event "a"; event "limit"; event "b" ] in
  (check (list string)) "parts" [ "text a"; "api 429 retryable=true provider=upstream" ] (List.map describe parts);
  Lwt.return_unit

(* A [Provider_error] from the event stream is pushed as it is and ends the
   stream. *)
let test_provider_error_kept () =
  let error =
    Ai_provider.Provider_error.make_api_error ~provider:"upstream" ~status:503 ~body:"down" ~is_retryable:true ()
  in
  let reads = ref [ event "a" ] in
  let events =
    Lwt_stream.from (fun () ->
      match !reads with
      | evt :: rest ->
        reads := rest;
        Lwt.return_some evt
      | [] -> Lwt.fail (Ai_provider.Provider_error.Provider_error error))
  in
  let%lwt parts = pumped_stream (fun (evt : Ai_provider.Sse.event) -> evt.data) events in
  (check (list string)) "parts" [ "text a"; "api 503 retryable=true provider=upstream" ] (List.map describe parts);
  Lwt.return_unit

let () =
  run "Stream_pump"
    [
      ( "pump",
        [
          test_case "malformed event skipped" `Quick (run_lwt test_malformed_event_skipped);
          test_case "decode errors carry raw data" `Quick (run_lwt test_decode_errors_carry_raw_data);
          test_case "unexpected exception ends stream" `Quick (run_lwt test_unexpected_exception_ends_stream);
          test_case "converter provider error kept" `Quick (run_lwt test_converter_provider_error_kept);
          test_case "provider error kept" `Quick (run_lwt test_provider_error_kept);
        ] );
    ]
