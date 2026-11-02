open Tiny_js

let run f = Lwt_main.run (Lwt_unix.with_timeout 60. (fun () -> f))
let binary = "./fake_runner.exe"

let payload =
  Alcotest.testable
    (fun fmt -> function
      | Vm.Text s -> Format.fprintf fmt "Text %S" s
      | Vm.Bytes s -> Format.fprintf fmt "Bytes %S" s)
    ( = )

let eval_result = Alcotest.(result (option payload) string)

let contains ~sub s =
  let n = String.length sub
  and m = String.length s in
  let rec go i =
    match i + n > m with
    | true -> false
    | false -> String.equal (String.sub s i n) sub || go (i + 1)
  in
  go 0

let check_error_contains name ~sub = function
  | Error msg -> Alcotest.(check bool) (Printf.sprintf "%s (%s)" name msg) true (contains ~sub msg)
  | Ok _ -> Alcotest.failf "%s: expected an error containing %S" name sub

let spawn_exn ?max_frame_bytes ?on_log ?(memory_limit_mb = 64) () =
  match%lwt Vm.spawn ~binary ~memory_limit_mb ?max_frame_bytes ?on_log () with
  | Ok vm -> Lwt.return vm
  | Error e -> Alcotest.failf "spawn failed: %s" e

let test_handshake_and_args () =
  run
    (let%lwt vm =
       match%lwt
         Vm.spawn ~binary ~sandbox:Vm.Seccomp ~memory_limit_mb:64 ~cpu_seconds:7 ~max_frame_bytes:4096 ~allow_clock:true
           ~allow_random:true ()
       with
       | Ok vm -> Lwt.return vm
       | Error e -> Alcotest.failf "spawn failed: %s" e
     in
     let%lwt r = Vm.eval vm "args" in
     Alcotest.check eval_result "flags"
       (Ok
          (Some
             (Vm.Text
                "--sandbox seccomp --memory-limit-mb 64 --cpu-seconds 7 --max-frame-bytes 4096 --allow-clock \
                 --allow-random")))
       r;
     let%lwt status = Vm.close vm in
     Alcotest.(check bool) "clean exit" true (status = Unix.WEXITED 0);
     Lwt.return_unit)

let test_default_args () =
  run
    (let%lwt vm = spawn_exn () in
     let%lwt r = Vm.eval vm "args" in
     Alcotest.check eval_result "only the memory limit and the frame cap"
       (Ok (Some (Vm.Text "--memory-limit-mb 64 --max-frame-bytes 16777216"))) r;
     let%lwt _ = Vm.close vm in
     Lwt.return_unit)

let test_bad_spawn () =
  run
    (let%lwt r = Vm.spawn ~binary ~memory_limit_mb:1 () in
     check_error_contains "wrong protocol version" ~sub:"unsupported protocol version 2" (Result.map ignore r);
     let%lwt r = Vm.spawn ~binary ~memory_limit_mb:2 () in
     check_error_contains "no hello" ~sub:"exit status 5" (Result.map ignore r);
     let%lwt r = Vm.spawn ~binary:"./does-not-exist" ~memory_limit_mb:64 () in
     Alcotest.(check bool) "missing binary" true (Result.is_error r);
     let%lwt r = Vm.spawn ~binary ~memory_limit_mb:0 () in
     Alcotest.(check bool) "bad memory limit" true (Result.is_error r);
     let%lwt r = Vm.spawn ~binary ~memory_limit_mb:64 ~max_frame_bytes:0 () in
     Alcotest.(check bool) "bad frame cap" true (Result.is_error r);
     Lwt.return_unit)

let test_eval_values () =
  run
    (let%lwt vm = spawn_exn () in
     let%lwt text = Vm.eval vm "text:héllo" in
     let%lwt bytes = Vm.eval vm "bytes:\000\001" in
     let%lwt null = Vm.eval vm "null" in
     let%lwt err = Vm.eval vm "error:boom" in
     Alcotest.check eval_result "text" (Ok (Some (Vm.Text "héllo"))) text;
     Alcotest.check eval_result "bytes" (Ok (Some (Vm.Bytes "\000\001"))) bytes;
     Alcotest.check eval_result "null" (Ok None) null;
     Alcotest.check eval_result "error" (Error "boom") err;
     Alcotest.(check bool) "alive after a JS error" true (Vm.is_alive vm);
     let%lwt _ = Vm.close vm in
     Lwt.return_unit)

let test_concurrent_evals () =
  run
    (let%lwt vm = spawn_exn () in
     let%lwt a, (b, c) = Lwt.both (Vm.eval vm "text:a") (Lwt.both (Vm.eval vm "text:b") (Vm.eval vm "error:c")) in
     Alcotest.check eval_result "a" (Ok (Some (Vm.Text "a"))) a;
     Alcotest.check eval_result "b" (Ok (Some (Vm.Text "b"))) b;
     Alcotest.check eval_result "c" (Error "c") c;
     let%lwt _ = Vm.close vm in
     Lwt.return_unit)

let test_invalid_code_and_oversize () =
  run
    (let%lwt vm = spawn_exn ~max_frame_bytes:1024 () in
     let%lwt r = Vm.eval vm "text:\xff" in
     check_error_contains "invalid utf-8" ~sub:"UTF-8" r;
     let%lwt r = Vm.eval vm ("text:" ^ String.make 2000 'a') in
     check_error_contains "oversized code" ~sub:"exceeds" r;
     let%lwt r = Vm.eval vm "text:still alive" in
     Alcotest.check eval_result "VM still usable" (Ok (Some (Vm.Text "still alive"))) r;
     let%lwt () =
       try%lwt
         let%lwt () = Vm.send vm (Vm.Bytes (String.make 2000 'a')) in
         Alcotest.fail "expected Invalid_argument"
       with Invalid_argument _ -> Lwt.return_unit
     in
     let%lwt _ = Vm.close vm in
     Lwt.return_unit)

let test_messages_and_echo () =
  run
    (let%lwt vm = spawn_exn () in
     let%lwt _ = Vm.eval vm "post:one" in
     let%lwt _ = Vm.eval vm "postbytes:\001\002" in
     let%lwt () = Vm.send vm (Vm.Text "ping") in
     let%lwt () = Vm.send vm (Vm.Bytes "\003\004") in
     let msgs = Vm.messages vm in
     let%lwt m = Lwt_stream.nget 4 msgs in
     Alcotest.(check (list payload))
       "messages in order"
       [ Vm.Text "one"; Vm.Bytes "\001\002"; Vm.Text "echo:ping"; Vm.Bytes "\003\004" ]
       m;
     let%lwt _ = Vm.close vm in
     let%lwt rest = Lwt_stream.to_list msgs in
     Alcotest.(check (list payload)) "stream ends after close" [] rest;
     Lwt.return_unit)

let test_logs () =
  run
    (let logs = ref [] in
     let on_log ~level text = logs := (level, text) :: !logs in
     let%lwt vm = spawn_exn ~on_log () in
     let%lwt _ = Vm.eval vm "log:warn:a:b" in
     let%lwt _ = Vm.eval vm "log:error:boom" in
     Alcotest.(check (list (pair string string))) "logs" [ "warn", "a:b"; "error", "boom" ] (List.rev !logs);
     let%lwt _ = Vm.close vm in
     Lwt.return_unit)

let test_process_death_fails_pending () =
  run
    (let%lwt vm = spawn_exn () in
     let hang = Vm.eval vm "hang" in
     let other = Vm.eval vm "hang" in
     let%lwt r = Vm.eval vm "die" in
     check_error_contains "die" ~sub:"exit status 3" r;
     let%lwt hang = hang
     and other = other in
     check_error_contains "pending 1" ~sub:"exit status 3" hang;
     check_error_contains "pending 2" ~sub:"exit status 3" other;
     let%lwt r = Vm.eval vm "text:x" in
     check_error_contains "eval after death" ~sub:"VM is dead" r;
     Alcotest.(check bool) "not alive" false (Vm.is_alive vm);
     let%lwt () =
       try%lwt Vm.send vm (Vm.Text "x")
       with Failure m ->
         Alcotest.(check bool) "send fails" true (contains ~sub:"dead" m);
         Lwt.return_unit
     in
     let%lwt rest = Lwt_stream.to_list (Vm.messages vm) in
     Alcotest.(check (list payload)) "stream ended" [] rest;
     let%lwt status = Vm.close vm in
     Alcotest.(check bool) "status" true (status = Unix.WEXITED 3);
     Lwt.return_unit)

let test_runner_error_reported () =
  run
    (let%lwt vm = spawn_exn () in
     let%lwt r = Vm.eval vm "runner_error" in
     check_error_contains "reason" ~sub:"scripted failure" r;
     check_error_contains "reason" ~sub:"exit status 4" r;
     let%lwt _ = Vm.close vm in
     Lwt.return_unit)

let test_protocol_violations_kill () =
  List.iter
    (fun (cmd, sub) ->
      run
        (let%lwt vm = spawn_exn () in
         let%lwt pending = Lwt.return (Vm.eval vm "hang") in
         let%lwt r = Vm.eval vm cmd in
         check_error_contains cmd ~sub r;
         let%lwt p = pending in
         check_error_contains (cmd ^ " pending") ~sub p;
         let%lwt _ = Vm.close vm in
         Lwt.return_unit))
    [ "garbage", "protocol violation"; "unknown_id", "unknown id 999999"; "huge", "exceeds" ]

let test_kill_and_close_twice () =
  run
    (let%lwt vm = spawn_exn () in
     let hang = Vm.eval vm "hang" in
     let%lwt status = Vm.kill vm in
     Alcotest.(check bool) "killed" true (status = Unix.WSIGNALED Sys.sigkill);
     let%lwt r = hang in
     check_error_contains "pending after kill" ~sub:"SIGKILL" r;
     let%lwt _ = Vm.close vm in
     Lwt.return_unit)

let () =
  Alcotest.run "vm"
    [
      ( "vm",
        [
          Alcotest.test_case "handshake and flags" `Quick test_handshake_and_args;
          Alcotest.test_case "default flags" `Quick test_default_args;
          Alcotest.test_case "bad spawn" `Quick test_bad_spawn;
          Alcotest.test_case "eval values" `Quick test_eval_values;
          Alcotest.test_case "concurrent evals" `Quick test_concurrent_evals;
          Alcotest.test_case "invalid and oversized input" `Quick test_invalid_code_and_oversize;
          Alcotest.test_case "messages" `Quick test_messages_and_echo;
          Alcotest.test_case "logs" `Quick test_logs;
          Alcotest.test_case "death fails pending evals" `Quick test_process_death_fails_pending;
          Alcotest.test_case "runner error" `Quick test_runner_error_reported;
          Alcotest.test_case "protocol violations kill the VM" `Quick test_protocol_violations_kill;
          Alcotest.test_case "kill" `Quick test_kill_and_close_twice;
        ] );
    ]
