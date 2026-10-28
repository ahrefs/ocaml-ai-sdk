open Alcotest
open Melange_json.Primitives

type args = { x : int } [@@deriving json]
type answer = { double : int } [@@deriving json]

let object_schema field = `Assoc [ "type", `String "object"; "required", `List [ `String field ] ]

let double =
  Ai_core.Tool.create ~name:"double" ~description:"Double a number"
    ~call:(Ai_core.Tool.codec ~to_json:args_to_json ~of_json:args_of_json ~schema:(object_schema "x"))
    ~response:(Ai_core.Tool.codec ~to_json:answer_to_json ~of_json:answer_of_json ~schema:(object_schema "double"))
    ~run:(fun _ { x } ->
      if x < 0 then Lwt.return_error { Ai_core.Tool.message = "negative"; data = None }
      else Lwt.return_ok { double = 2 * x })
    ()

let options = Ai_core.Core_tool.execute_options ~tool_call_id:"c1" ()
let execute_double args = Lwt_main.run (Ai_core.Tool.execute double args options)
let json = testable (fun fmt j -> Format.pp_print_string fmt (Yojson.Basic.to_string j)) Yojson.Basic.equal

let test_execute_ok () =
  match execute_double (`Assoc [ "x", `Int 4 ]) with
  | Ok v -> (check json) "response" (`Assoc [ "double", `Int 8 ]) v
  | Error _ -> fail "expected Ok"

let test_execute_tool_error () =
  match execute_double (`Assoc [ "x", `Int (-1) ]) with
  | Error { message; _ } -> (check string) "message" "negative" message
  | Ok _ -> fail "expected Error"

let test_execute_invalid_args () =
  match execute_double (`Assoc [ "x", `String "no" ]) with
  | Error { message; _ } -> (check bool) "prefixed" true (String.starts_with ~prefix:"Invalid arguments" message)
  | Ok _ -> fail "expected Error"

let test_accessors () =
  (check string) "name" "double" (Ai_core.Tool.name double);
  (check (option string)) "description" (Some "Double a number") (Ai_core.Tool.description double);
  (check json) "schema" (object_schema "x") (Ai_core.Tool.call_schema double)

let test_codec_exceptions () =
  let raising =
    { Ai_core.Tool.to_json = (fun () -> failwith "enc"); of_json = (fun _ -> failwith "dec"); schema = `Null }
  in
  let tool ~call = Ai_core.Tool.create ~name:"t" ~call ~response:raising ~run:(fun _ _ -> Lwt.return_ok ()) () in
  let message tool =
    match Lwt_main.run (Ai_core.Tool.execute tool `Null options) with
    | Error { message; _ } -> message
    | Ok _ -> fail "expected Error"
  in
  (check string) "args" "Invalid arguments: Failure(\"dec\")" (message (tool ~call:raising));
  (check string) "response" "Invalid response: Failure(\"enc\")"
    (message (tool ~call:{ Ai_core.Tool.to_json = (fun () -> `Null); of_json = (fun _ -> Ok ()); schema = `Null }))

let test_needs_approval () =
  let tool =
    Ai_core.Tool.create ~name:"t"
      ~call:(Ai_core.Tool.codec ~to_json:args_to_json ~of_json:args_of_json ~schema:(object_schema "x"))
      ~response:(Ai_core.Tool.codec ~to_json:answer_to_json ~of_json:answer_of_json ~schema:(object_schema "double"))
      ~needs_approval:(fun { x } -> Lwt.return (x > 10))
      ~run:(fun _ { x } -> Lwt.return_ok { double = 2 * x })
      ()
  in
  let ask args =
    match (snd (Ai_core.Tool.to_core_tool tool)).needs_approval with
    | Some needs_approval -> Lwt_main.run (needs_approval args)
    | None -> fail "expected needs_approval"
  in
  (check bool) "big" true (ask (`Assoc [ "x", `Int 11 ]));
  (check bool) "small" false (ask (`Assoc [ "x", `Int 1 ]));
  (check bool) "invalid" false (ask (`Assoc [ "x", `String "no" ]));
  (check bool) "none" true (Option.is_none (snd (Ai_core.Tool.to_core_tool double)).needs_approval)

let test_to_core_tool () =
  let name, core = Ai_core.Tool.to_core_tool double in
  (check string) "name" "double" name;
  match core.execute with
  | None -> fail "expected execute"
  | Some execute ->
    (check json) "response" (`Assoc [ "double", `Int 10 ]) (Lwt_main.run (execute (`Assoc [ "x", `Int 5 ]) options));
    (match Lwt_main.run (execute (`Assoc [ "x", `Int (-1) ]) options) with
    | _ -> fail "expected failure"
    | exception exn -> (check string) "printed" "negative" (Printexc.to_string exn))

let () =
  run "Tool"
    [
      ( "tool",
        [
          test_case "execute ok" `Quick test_execute_ok;
          test_case "execute tool error" `Quick test_execute_tool_error;
          test_case "execute invalid args" `Quick test_execute_invalid_args;
          test_case "accessors" `Quick test_accessors;
          test_case "codec exceptions" `Quick test_codec_exceptions;
          test_case "needs_approval" `Quick test_needs_approval;
          test_case "to_core_tool" `Quick test_to_core_tool;
        ] );
    ]
