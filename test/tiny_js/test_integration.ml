(* Tests against the real tiny-js-sandbox binary: TINY_JS_SANDBOX_BIN, else lib/tiny-js-sandbox/target/release/tiny-js-sandbox, else the location `make
   build-tiny-js-binary` uses (_build/tiny-js-sandbox/release/tiny-js-sandbox), relative to the workspace root.
   When none exists the cases are reported as skipped, unless TINY_JS_REQUIRE_BINARY is set (`make
   test-tiny-js` sets it), in which case they fail. *)

open Tiny_js

(* Takes a thunk, so that nothing starts before the timeout applies. *)
let run f = Lwt_main.run (Lwt_unix.with_timeout 120. f)

let contains ~sub s =
  let n = String.length sub
  and m = String.length s in
  let rec go i =
    match i + n > m with
    | true -> false
    | false -> String.equal (String.sub s i n) sub || go (i + 1)
  in
  go 0

(* The source root is the parent of the [_build] directory the test runs in. *)
let workspace_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None ->
    let rec up dir =
      match Filename.basename dir, Filename.dirname dir with
      | "_build", parent -> parent
      | _, parent when String.equal parent dir -> Sys.getcwd ()
      | _, parent -> up parent
    in
    up (Sys.getcwd ())

let binary =
  let candidates =
    let root = workspace_root () in
    List.concat
      [
        Option.to_list (Sys.getenv_opt "TINY_JS_SANDBOX_BIN");
        [
          Filename.concat root "lib/tiny-js-sandbox/target/release/tiny-js-sandbox";
          Filename.concat root "_build/tiny-js-sandbox/release/tiny-js-sandbox";
        ];
      ]
  in
  List.find_opt Sys.file_exists candidates

let payload =
  Alcotest.testable
    (fun fmt -> function
      | Vm.Text s -> Format.fprintf fmt "Text %S" s
      | Vm.Bytes s -> Format.fprintf fmt "Bytes %S" s)
    (fun a b ->
      match a, b with
      | Vm.Text x, Vm.Text y | Vm.Bytes x, Vm.Bytes y -> String.equal x y
      | Vm.Text _, Vm.Bytes _ | Vm.Bytes _, Vm.Text _ -> false)

let is_exit_0 = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let is_sigkill = function
  | Unix.WSIGNALED s -> Int.equal s Sys.sigkill
  | Unix.WEXITED _ | Unix.WSTOPPED _ -> false

let is_error_frame fields =
  match List.assoc_opt "t" fields with
  | Some (Cbor.Text t) -> String.equal t "error"
  | Some (Cbor.Null | Cbor.Bool _ | Cbor.Int _ | Cbor.Bytes _ | Cbor.Array _ | Cbor.Map _) | None -> false

let eval_result = Alcotest.(result (option payload) string)

let check_error_contains name ~sub = function
  | Error msg -> Alcotest.(check bool) (Printf.sprintf "%s (%s)" name msg) true (contains ~sub msg)
  | Ok _ -> Alcotest.failf "%s: expected an error containing %S" name sub

let check_is_error name = function
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s: expected an error" name

let binary_required =
  match Sys.getenv_opt "TINY_JS_REQUIRE_BINARY" with
  | Some ("" | "0") | None -> false
  | Some _ -> true

let with_binary f () =
  match binary, binary_required with
  | Some binary, _ -> f binary
  | None, true -> Alcotest.fail "tiny-js-sandbox binary not found, and TINY_JS_REQUIRE_BINARY is set"
  | None, false -> Alcotest.skip ()

let spawn_exn ~binary ?sandbox ?(memory_limit_mb = 64) ?cpu_seconds ?max_frame_bytes ?allow_clock ?allow_random ?on_log
  () =
  match%lwt
    Vm.spawn ~binary ?sandbox ~memory_limit_mb ?cpu_seconds ?max_frame_bytes ?allow_clock ?allow_random ?on_log ()
  with
  | Ok vm -> Lwt.return vm
  | Error e -> Alcotest.failf "spawn failed: %s" e

let with_vm ~binary ?sandbox ?memory_limit_mb ?cpu_seconds ?max_frame_bytes ?allow_clock ?allow_random ?on_log f =
  let%lwt vm =
    spawn_exn ~binary ?sandbox ?memory_limit_mb ?cpu_seconds ?max_frame_bytes ?allow_clock ?allow_random ?on_log ()
  in
  let%lwt () = f vm in
  let%lwt _ = Vm.close vm in
  Lwt.return_unit

let eval_text vm code =
  match%lwt Vm.eval vm code with
  | Ok (Some (Vm.Text s)) -> Lwt.return s
  | Ok (Some (Vm.Bytes _) | None) -> Alcotest.failf "%s: expected a text result" code
  | Error e -> Alcotest.failf "%s: eval failed: %s" code e

let next_message vm =
  match%lwt Lwt_unix.with_timeout 10. (fun () -> Lwt_stream.get (Vm.messages vm)) with
  | Some m -> Lwt.return m
  | None -> Alcotest.fail "message stream ended"

let test_handshake_and_eval binary =
  run (fun () ->
    with_vm ~binary (fun vm ->
      let%lwt text = Vm.eval vm {|"a" + "b"|} in
      Alcotest.check eval_result "text" (Ok (Some (Vm.Text "ab"))) text;
      let%lwt bytes = Vm.eval vm "new Uint8Array([1, 2, 255])" in
      Alcotest.check eval_result "bytes" (Ok (Some (Vm.Bytes "\001\002\255"))) bytes;
      let%lwt buf = Vm.eval vm "new Uint8Array([7, 8]).buffer" in
      Alcotest.check eval_result "array buffer" (Ok (Some (Vm.Bytes "\007\008"))) buf;
      let%lwt undef = Vm.eval vm "undefined" in
      Alcotest.check eval_result "undefined" (Ok None) undef;
      let%lwt null = Vm.eval vm "null" in
      Alcotest.check eval_result "null" (Ok None) null;
      let%lwt err = Vm.eval vm {|throw new Error("boom")|} in
      check_error_contains "exception" ~sub:"boom" err;
      let%lwt num = Vm.eval vm "1 + 1" in
      check_error_contains "number" ~sub:"not transferable" num;
      let%lwt set = Vm.eval vm "globalThis.counter = 41; 'set'" in
      Alcotest.check eval_result "setup" (Ok (Some (Vm.Text "set"))) set;
      let%lwt persisted = eval_text vm "String(counter + 1)" in
      Alcotest.(check string) "globals persist across evals" "42" persisted;
      Alcotest.(check bool) "alive" true (Vm.is_alive vm);
      Lwt.return_unit))

let test_post_and_onmessage binary =
  run (fun () ->
    with_vm ~binary (fun vm ->
      let%lwt r = Vm.eval vm {|host.post("hi"); host.post(new Uint8Array([1, 2]))|} in
      Alcotest.check eval_result "post returns undefined" (Ok None) r;
      let%lwt m1 = next_message vm in
      let%lwt m2 = next_message vm in
      Alcotest.check payload "text message" (Vm.Text "hi") m1;
      Alcotest.check payload "bytes message" (Vm.Bytes "\001\002") m2;
      let%lwt _ =
        Vm.eval vm
          {|host.onmessage = function (x) {
                 host.post(typeof x === "string" ? "text:" + x : new Uint8Array(x));
               }|}
      in
      let%lwt () = Vm.send vm (Vm.Text "yo") in
      let%lwt () = Vm.send vm (Vm.Bytes "\009\010") in
      let%lwt m3 = next_message vm in
      let%lwt m4 = next_message vm in
      Alcotest.check payload "text round trip" (Vm.Text "text:yo") m3;
      Alcotest.check payload "bytes round trip" (Vm.Bytes "\009\010") m4;
      let%lwt r = Vm.eval vm "host.post(42)" in
      check_error_contains "post of a number" ~sub:"TypeError" r;
      Lwt.return_unit))

let test_promise_drain_and_log_warnings binary =
  run (fun () ->
    let logs = ref [] in
    let on_log ~level text = logs := (level, text) :: !logs in
    with_vm ~binary ~on_log (fun vm ->
      let%lwt _ = Vm.eval vm {|Promise.resolve().then(() => host.post("from job"))|} in
      let%lwt m = next_message vm in
      Alcotest.check payload "job drained" (Vm.Text "from job") m;
      (* no onmessage handler yet: dropped with a warning *)
      let%lwt () = Vm.send vm (Vm.Text "dropped") in
      let%lwt _ = Vm.eval vm {|console.log("hello", 1)|} in
      Alcotest.(check bool) "warn logged" true (List.exists (fun (l, _) -> String.equal l "warn") !logs);
      Alcotest.(check bool)
        "console.log captured" true
        (List.exists (fun (l, t) -> String.equal l "log" && String.equal t "hello 1") !logs);
      let%lwt _ = Vm.eval vm {|host.onmessage = () => { throw new Error("handler failed") }|} in
      let%lwt () = Vm.send vm (Vm.Text "x") in
      let%lwt alive = eval_text vm {|"still alive"|} in
      Alcotest.(check string) "VM survives a throwing handler" "still alive" alive;
      Alcotest.(check bool)
        "error logged" true
        (List.exists (fun (l, t) -> String.equal l "error" && contains ~sub:"handler failed" t) !logs);
      Lwt.return_unit))

let test_oversized_frames binary =
  run (fun () ->
    with_vm ~binary ~max_frame_bytes:4096 (fun vm ->
      let%lwt r = Vm.eval vm (Printf.sprintf {|"%s"|} (String.make 5000 'a')) in
      check_error_contains "oversized eval refused by the client" ~sub:"exceeds" r;
      let%lwt r = Vm.eval vm {|host.post("x".repeat(5000))|} in
      check_error_contains "oversized host.post" ~sub:"RangeError" r;
      let%lwt r = Vm.eval vm {|"y".repeat(5000)|} in
      check_error_contains "oversized eval result" ~sub:"exceed" r;
      let%lwt ok = eval_text vm {|"fine"|} in
      Alcotest.(check string) "VM alive" "fine" ok;
      Lwt.return_unit));
  (* A frame above the runner's cap is fatal: error frame, then non-zero exit. *)
  Fun.id
    (fun binary ->
      run (fun () ->
        let proc =
          Lwt_process.open_process ~stderr:`Dev_null
            (binary, [| binary; "--sandbox"; "none"; "--memory-limit-mb"; "64"; "--max-frame-bytes"; "1024" |])
        in
        let%lwt hello = Frame.read ~max_frame_bytes:1024 proc#stdout in
        Alcotest.(check bool) "hello" true (Result.is_ok hello);
        let%lwt () = Lwt_io.write proc#stdin "\000\008\000\000" in
        let%lwt () = Lwt_io.flush proc#stdin in
        let%lwt err = Frame.read ~max_frame_bytes:1024 proc#stdout in
        (match err with
        | Ok (Some payload) ->
          (match Cbor.decode payload with
          | Ok (Cbor.Map fields) -> Alcotest.(check bool) "error frame" true (is_error_frame fields)
          | Ok _ | Error _ -> Alcotest.fail "unexpected reply")
        | Ok None | Error _ -> Alcotest.fail "expected an error frame");
        let%lwt status = proc#status in
        Alcotest.(check bool) "non-zero exit" false (is_exit_0 status);
        Lwt.return_unit))
    binary

let test_lone_surrogates_and_huge_payloads binary =
  run (fun () ->
    with_vm ~binary ~max_frame_bytes:4096 ~memory_limit_mb:256 (fun vm ->
      let%lwt r = Vm.eval vm {|"a\ud800b"|} in
      Alcotest.check eval_result "lone surrogate in a result" (Ok (Some (Vm.Text "a\xef\xbf\xbdb"))) r;
      let%lwt r = Vm.eval vm {|host.post("x\udc00y"); undefined|} in
      Alcotest.check eval_result "post returns" (Ok None) r;
      let%lwt m = next_message vm in
      Alcotest.check payload "lone surrogate in a post" (Vm.Text "x\xef\xbf\xbdy") m;
      let%lwt r = Vm.eval vm "new ArrayBuffer(50 * 1024 * 1024)" in
      check_error_contains "huge buffer result" ~sub:"maximum frame size" r;
      let%lwt r = Vm.eval vm "host.post(new Uint8Array(50 * 1024 * 1024))" in
      check_error_contains "huge buffer post" ~sub:"RangeError" r;
      let%lwt ok = eval_text vm {|"fine"|} in
      Alcotest.(check string) "VM alive" "fine" ok;
      Lwt.return_unit))

let test_malformed_input_is_fatal binary =
  run (fun () ->
    let proc =
      Lwt_process.open_process ~stderr:`Dev_null (binary, [| binary; "--sandbox"; "none"; "--memory-limit-mb"; "64" |])
    in
    let%lwt _ = Frame.read ~max_frame_bytes:1024 proc#stdout in
    (* a valid frame header with a float payload *)
    let%lwt w = Frame.write ~max_frame_bytes:1024 proc#stdin "\xfb\x3f\xf0\x00\x00\x00\x00\x00\x00" in
    Alcotest.(check bool) "written" true (Result.is_ok w);
    let%lwt status = proc#status in
    Alcotest.(check bool) "non-zero exit" false (is_exit_0 status);
    Lwt.return_unit)

let test_memory_limit binary =
  run (fun () ->
    with_vm ~binary ~memory_limit_mb:16 (fun vm ->
      let%lwt r = Vm.eval vm {|var a = []; for (;;) { a.push(new Array(100000).fill(1)); }|} in
      check_error_contains "memory exhaustion" ~sub:"out of memory" r;
      Lwt.return_unit))

let test_cpu_limit binary =
  run (fun () ->
    let%lwt vm = spawn_exn ~binary ~cpu_seconds:1 () in
    let%lwt r = Vm.eval vm "for (;;) {}" in
    check_error_contains "cpu limit" ~sub:"VM is dead" r;
    Alcotest.(check bool) "dead" false (Vm.is_alive vm);
    let%lwt _ = Vm.close vm in
    Lwt.return_unit)

let test_death_fails_pending binary =
  run (fun () ->
    let%lwt vm = spawn_exn ~binary () in
    let spinning = Vm.eval vm "for (;;) {}" in
    let%lwt () = Lwt_unix.sleep 0.2 in
    let%lwt status = Vm.kill vm in
    Alcotest.(check bool) "killed" true (is_sigkill status);
    let%lwt r = spinning in
    check_error_contains "pending eval" ~sub:"VM is dead" r;
    let%lwt rest = Lwt_stream.to_list (Vm.messages vm) in
    Alcotest.(check int) "stream ended" 0 (List.length rest);
    Lwt.return_unit)

let test_close_exits_cleanly binary =
  run (fun () ->
    let%lwt vm = spawn_exn ~binary () in
    let%lwt status = Vm.close vm in
    Alcotest.(check bool) "exit 0 on stdin EOF" true (is_exit_0 status);
    Lwt.return_unit)

let test_flags binary =
  let check ~allow_clock ~allow_random =
    run (fun () ->
      with_vm ~binary ~allow_clock ~allow_random (fun vm ->
        let name what = Printf.sprintf "%s (clock=%b random=%b)" what allow_clock allow_random in
        let%lwt date = eval_text vm "typeof Date" in
        Alcotest.(check string) (name "typeof Date") (if allow_clock then "function" else "undefined") date;
        let%lwt rnd = Vm.eval vm {|var r = Math.random(); String(r >= 0 && r < 1)|} in
        (match allow_random with
        | true -> Alcotest.check eval_result (name "Math.random") (Ok (Some (Vm.Text "true"))) rnd
        | false -> check_error_contains (name "Math.random") ~sub:"Math.random is disabled in this sandbox" rnd);
        let%lwt () =
          match allow_clock with
          | true ->
            let%lwt now = eval_text vm {|String(typeof Date.now())|} in
            Alcotest.(check string) (name "Date.now") "number" now;
            Lwt.return_unit
          | false ->
            let%lwt r = Vm.eval vm "new Date()" in
            check_error_contains (name "using Date") ~sub:"ReferenceError: Date is not defined" r;
            Lwt.return_unit
        in
        Lwt.return_unit))
  in
  List.iter
    (fun (allow_clock, allow_random) -> check ~allow_clock ~allow_random)
    [ false, false; true, false; false, true; true, true ]

let () =
  let case name f = Alcotest.test_case name `Slow (with_binary f) in
  Alcotest.run "tiny-js-sandbox integration"
    [
      ( "binary",
        [
          case "handshake and eval" test_handshake_and_eval;
          case "post and onmessage" test_post_and_onmessage;
          case "promise jobs, logs, handler errors" test_promise_drain_and_log_warnings;
          case "oversized frames" test_oversized_frames;
          case "lone surrogates and huge payloads" test_lone_surrogates_and_huge_payloads;
          case "malformed input is fatal" test_malformed_input_is_fatal;
          case "memory limit" test_memory_limit;
          case "cpu limit" test_cpu_limit;
          case "process death fails pending evals" test_death_fails_pending;
          case "close exits cleanly" test_close_exits_cleanly;
          case "clock and random flags" test_flags;
        ] );
    ]
