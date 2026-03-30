open Alcotest

let test_tool_without_approval () =
  let tool : Ai_core.Core_tool.t =
    Ai_core.Core_tool.create ~description:"test"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ -> Lwt.return (`String "ok"))
      ()
  in
  (check bool) "no approval" true (Option.is_none tool.needs_approval)

let test_tool_with_static_approval () =
  let tool =
    Ai_core.Core_tool.create_with_approval ~description:"dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ -> Lwt.return (`String "ok"))
      ()
  in
  match tool.needs_approval with
  | None -> Alcotest.fail "expected needs_approval to be Some"
  | Some check_fn ->
    let needs = Lwt_main.run (check_fn `Null) in
    (check bool) "always true" true needs

let test_tool_with_dynamic_approval () =
  let tool =
    Ai_core.Core_tool.create ~description:"conditional"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~needs_approval:(fun args ->
        match args with
        | `Assoc props ->
          (match List.assoc_opt "amount" props with
          | Some (`Int n) -> Lwt.return (n > 1000)
          | _ -> Lwt.return_false)
        | _ -> Lwt.return_false)
      ~execute:(fun _ -> Lwt.return (`String "ok"))
      ()
  in
  let check_fn =
    match tool.needs_approval with
    | None -> Alcotest.fail "expected needs_approval to be Some"
    | Some f -> f
  in
  let needs_high = Lwt_main.run (check_fn (`Assoc [ "amount", `Int 5000 ])) in
  let needs_low = Lwt_main.run (check_fn (`Assoc [ "amount", `Int 100 ])) in
  (check bool) "high amount needs approval" true needs_high;
  (check bool) "low amount no approval" false needs_low

let () =
  run "Core_tool"
    [
      ( "create",
        [
          test_case "without_approval" `Quick test_tool_without_approval;
          test_case "static_approval" `Quick test_tool_with_static_approval;
          test_case "dynamic_approval" `Quick test_tool_with_dynamic_approval;
        ] );
    ]
