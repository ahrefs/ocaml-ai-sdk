open Alcotest

let test_tool_without_approval () =
  let tool : Ai_core.Core_tool.t =
    Ai_core.Core_tool.create ~description:"test"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ _ -> Lwt.return (`String "ok"))
      ()
  in
  (check bool) "no approval" true (Option.is_none tool.needs_approval)

let test_tool_with_static_approval () =
  let tool =
    Ai_core.Core_tool.create_with_approval ~description:"dangerous"
      ~parameters:(`Assoc [ "type", `String "object" ])
      ~execute:(fun _ _ -> Lwt.return (`String "ok"))
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
      ~execute:(fun _ _ -> Lwt.return (`String "ok"))
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

(* Runs a tool that fails with [exn] and names the outcome: "error result:
   <text>" for an error result, or the exception [execute_tool] raised. *)
let execute_failing_tool exn =
  let tool =
    Ai_core.Core_tool.create ~parameters:(`Assoc [ "type", `String "object" ]) ~execute:(fun _ _ -> Lwt.fail exn) ()
  in
  Lwt_main.run
    (Lwt.catch
       (fun () ->
         let%lwt (result : Ai_core.Generate_text_result.tool_result) =
           Ai_core.Core_tool.execute_tool
             ~tools:[ "failing", tool ]
             ~messages:[] ~tool_call_id:"tc_1" ~tool_name:"failing" ~args:(`Assoc []) ()
         in
         match result.is_error, result.result with
         | true, `String text -> Lwt.return ("error result: " ^ text)
         | (true | false), json -> Lwt.return ("result: " ^ Yojson.Basic.to_string json))
       (function
         | Lwt.Canceled -> Lwt.return "raised Canceled"
         | Ai_provider.Abort_signal.Aborted _ -> Lwt.return "raised Aborted"
         | exn -> Lwt.return ("raised " ^ Printexc.to_string exn)))

let test_canceled_reraised () = (check string) "outcome" "raised Canceled" (execute_failing_tool Lwt.Canceled)

let test_aborted_reraised () =
  (check string) "outcome" "raised Aborted" (execute_failing_tool (Ai_provider.Abort_signal.Aborted { reason = None }))

let test_other_exception_is_error_result () =
  (check string) "outcome" "error result: Failure(\"boom\")" (execute_failing_tool (Failure "boom"))

let () =
  run "Core_tool"
    [
      ( "create",
        [
          test_case "without_approval" `Quick test_tool_without_approval;
          test_case "static_approval" `Quick test_tool_with_static_approval;
          test_case "dynamic_approval" `Quick test_tool_with_dynamic_approval;
        ] );
      ( "execute_tool",
        [
          test_case "canceled_reraised" `Quick test_canceled_reraised;
          test_case "aborted_reraised" `Quick test_aborted_reraised;
          test_case "other_exception_is_error_result" `Quick test_other_exception_is_error_result;
        ] );
    ]
