open Alcotest

let test_default_values () =
  let t = Ai_provider.Http_timeouts.default in
  (check (float 1e-6)) "request_timeout default" 600.0 t.request_timeout;
  (check (float 1e-6)) "stream_idle_timeout default" 300.0 t.stream_idle_timeout

let test_create_override_request () =
  let t = Ai_provider.Http_timeouts.create ~request_timeout:30.0 () in
  (check (float 1e-6)) "override request" 30.0 t.request_timeout;
  (check (float 1e-6)) "default idle preserved" 300.0 t.stream_idle_timeout

let test_create_override_idle () =
  let t = Ai_provider.Http_timeouts.create ~stream_idle_timeout:15.0 () in
  (check (float 1e-6)) "default request preserved" 600.0 t.request_timeout;
  (check (float 1e-6)) "override idle" 15.0 t.stream_idle_timeout

let test_create_rejects_zero () =
  check_raises "zero rejected"
    (Invalid_argument "Http_timeouts.create: request_timeout must be positive (got 0.000000)") (fun () ->
    ignore (Ai_provider.Http_timeouts.create ~request_timeout:0.0 () : Ai_provider.Http_timeouts.t))

let test_create_rejects_negative () =
  check_raises "negative rejected"
    (Invalid_argument "Http_timeouts.create: stream_idle_timeout must be positive (got -1.000000)") (fun () ->
    ignore (Ai_provider.Http_timeouts.create ~stream_idle_timeout:(-1.0) () : Ai_provider.Http_timeouts.t))

let () =
  run "Http_timeouts"
    [
      ( "construction",
        [
          test_case "default values" `Quick test_default_values;
          test_case "override request_timeout" `Quick test_create_override_request;
          test_case "override stream_idle_timeout" `Quick test_create_override_idle;
          test_case "rejects zero" `Quick test_create_rejects_zero;
          test_case "rejects negative" `Quick test_create_rejects_negative;
        ] );
    ]
