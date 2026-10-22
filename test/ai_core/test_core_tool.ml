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

(* Names the outcome of an [execute_tool] call: "error result: <text>" for an
   error result, or the exception it failed with. *)
let outcome_name promise =
  match Lwt.state promise with
  | Lwt.Return { Ai_core.Generate_text_result.is_error = true; result = `String text; _ } -> "error result: " ^ text
  | Lwt.Return { result; _ } -> "result: " ^ Yojson.Basic.to_string result
  | Lwt.Fail Lwt.Canceled -> "raised Canceled"
  | Lwt.Fail (Ai_provider.Abort_signal.Aborted { reason = None }) -> "raised Aborted"
  | Lwt.Fail (Ai_provider.Abort_signal.Aborted { reason = Some reason }) ->
    "raised Aborted: " ^ Printexc.to_string reason
  | Lwt.Fail exn -> "raised " ^ Printexc.to_string exn
  | Lwt.Sleep -> "pending"

let execute ?abort_signal execute =
  let tool = Ai_core.Core_tool.create ~parameters:(`Assoc [ "type", `String "object" ]) ~execute () in
  Ai_core.Core_tool.execute_tool ?abort_signal
    ~tools:[ "failing", tool ]
    ~messages:[] ~tool_call_id:"tc_1" ~tool_name:"failing" ~args:(`Assoc []) ()

(* Runs a tool that fails with [exn] and names the outcome. *)
let execute_failing_tool exn = outcome_name (execute (fun _ _ -> Lwt.fail exn))

(* The tool's own cancel or abort, such as a timeout of its own, is its
   result: the call has no signal and was not cancelled. *)
let test_own_canceled_is_error_result () =
  (check string) "outcome" "error result: Lwt.Resolution_loop.Canceled" (execute_failing_tool Lwt.Canceled)

let test_own_aborted_is_error_result () =
  (check string) "outcome" "error result: Abort_signal.Aborted(Abort_signal.Timeout(1s))"
    (execute_failing_tool
       (Ai_provider.Abort_signal.Aborted { reason = Some (Ai_provider.Abort_signal.Timeout { after_s = 1. }) }))

(* Once the call's signal has fired, any failure of the tool is the abort. *)
let test_failure_after_signal_is_abort () =
  let abort_signal, abort = Ai_provider.Abort_signal.create () in
  let outcome =
    execute ~abort_signal (fun _ _ ->
      abort ~reason:Exit ();
      Lwt.fail (Failure "stopped"))
  in
  (check string) "outcome" "raised Aborted: Stdlib.Exit" (outcome_name outcome)

(* Cancelling [execute_tool] fails it with [Canceled] and cancels the tool,
   even though the tool's own [Canceled] would be its result. *)
let test_cancel_of_execute_tool () =
  let work, (_ : Yojson.Basic.t Lwt.u) = Lwt.task () in
  let outcome = execute (fun _ _ -> work) in
  Lwt.cancel outcome;
  (check string) "outcome" "raised Canceled" (outcome_name outcome);
  (check bool) "tool cancelled" true
    (match Lwt.state work with
    | Lwt.Fail Lwt.Canceled -> true
    | Lwt.Fail _ | Lwt.Return _ | Lwt.Sleep -> false)

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
          test_case "own_canceled_is_error_result" `Quick test_own_canceled_is_error_result;
          test_case "own_aborted_is_error_result" `Quick test_own_aborted_is_error_result;
          test_case "failure_after_signal_is_abort" `Quick test_failure_after_signal_is_abort;
          test_case "cancel_of_execute_tool" `Quick test_cancel_of_execute_tool;
          test_case "other_exception_is_error_result" `Quick test_other_exception_is_error_result;
        ] );
    ]
