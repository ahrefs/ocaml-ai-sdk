type 'a codec = {
  to_json : 'a -> Yojson.Basic.t;
  of_json : Yojson.Basic.t -> ('a, string) result;
  schema : Yojson.Basic.t;
}

let codec ~to_json ~of_json ~schema =
  let of_json json =
    try Ok (of_json json) with
    | Melange_json.Of_json_error (Json_error msg | Unexpected_variant msg) -> Error msg
    | Melange_json.Of_string_error msg -> Error msg
  in
  { to_json; of_json; schema }

type error = {
  message : string;
  data : Yojson.Basic.t option;
}

exception Failed of error

let () =
  Printexc.register_printer (function
    | Failed { message; data = None } -> Some message
    | Failed { message; data = Some data } -> Some (Printf.sprintf "%s %s" message (Yojson.Basic.to_string data))
    | _ -> None)

type t =
  | Tool : {
      name : string;
      description : string option;
      call : 'c codec;
      response : 'r codec;
      run : Core_tool.execute_options -> 'c -> ('r, error) result Lwt.t;
      needs_approval : ('c -> bool Lwt.t) option;
    }
      -> t

let create ?description ?needs_approval ~name ~call ~response ~run () =
  Tool { name; description; call; response; run; needs_approval }

let name (Tool t) = t.name
let description (Tool t) = t.description
let call_schema (Tool t) = t.call.schema
let response_schema (Tool t) = t.response.schema

let invalid ~what msg = { message = Printf.sprintf "Invalid %s: %s" what msg; data = None }

(* Codecs built without {!codec} may raise. *)
let decode codec json = try codec.of_json json with exn -> Error (Printexc.to_string exn)

let encode codec value =
  try Ok (codec.to_json value) with exn -> Error (invalid ~what:"response" (Printexc.to_string exn))

let execute (Tool t) args options =
  match decode t.call args with
  | Error msg -> Lwt.return_error (invalid ~what:"arguments" msg)
  | Ok call ->
    let%lwt result = t.run options call in
    Lwt.return (Result.bind result (encode t.response))

let to_core_tool ?provider_options (Tool t as tool) =
  let needs_approval =
    Option.map
      (fun needs_approval args ->
        match decode t.call args with
        | Ok call -> needs_approval call
        | Error _ -> Lwt.return_false)
      t.needs_approval
  in
  let execute args options =
    match%lwt execute tool args options with
    | Ok json -> Lwt.return json
    | Error error -> Lwt.fail (Failed error)
  in
  let core =
    Core_tool.create ?description:t.description ?needs_approval ?provider_options ~parameters:t.call.schema ~execute ()
  in
  t.name, core
