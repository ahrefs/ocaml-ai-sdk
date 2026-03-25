open Alcotest

let test_make_sse_response_basic () =
  let stream, push = Lwt_stream.create () in
  push (Some "data: {\"type\":\"start\"}\n\n");
  push (Some "data: [DONE]\n\n");
  push None;
  let response, body = Lwt_main.run (Ai_core.Server_handler.make_sse_response stream) in
  let headers = Cohttp.Response.headers response in
  (check (option string)) "content-type" (Some "text/event-stream") (Cohttp.Header.get headers "content-type");
  (check (option string)) "protocol" (Some "v1") (Cohttp.Header.get headers "x-vercel-ai-ui-message-stream");
  let body_str = Lwt_main.run (Cohttp_lwt.Body.to_string body) in
  (check bool) "contains data" true (String.length body_str > 0)

let test_make_sse_response_all_headers () =
  let stream, push = Lwt_stream.create () in
  push None;
  let response, _body = Lwt_main.run (Ai_core.Server_handler.make_sse_response stream) in
  let headers = Cohttp.Response.headers response in
  (check (option string)) "cache-control" (Some "no-cache") (Cohttp.Header.get headers "cache-control");
  (check (option string)) "connection" (Some "keep-alive") (Cohttp.Header.get headers "connection");
  (check (option string)) "x-accel-buffering" (Some "no") (Cohttp.Header.get headers "x-accel-buffering")

let test_make_sse_response_extra_headers () =
  let stream, push = Lwt_stream.create () in
  push None;
  let response, _body =
    Lwt_main.run (Ai_core.Server_handler.make_sse_response ~extra_headers:[ "x-custom", "value" ] stream)
  in
  let headers = Cohttp.Response.headers response in
  (check (option string)) "custom header" (Some "value") (Cohttp.Header.get headers "x-custom")

let test_make_sse_response_custom_status () =
  let stream, push = Lwt_stream.create () in
  push None;
  let response, _body = Lwt_main.run (Ai_core.Server_handler.make_sse_response ~status:`Bad_request stream) in
  let status = Cohttp.Response.status response in
  (check int) "status code" 400 (Cohttp.Code.code_of_status status)

let test_make_sse_response_body_content () =
  let stream, push = Lwt_stream.create () in
  push (Some "data: hello\n\n");
  push (Some "data: world\n\n");
  push None;
  let _response, body = Lwt_main.run (Ai_core.Server_handler.make_sse_response stream) in
  let body_str = Lwt_main.run (Cohttp_lwt.Body.to_string body) in
  (check string) "body content" "data: hello\n\ndata: world\n\n" body_str

let () =
  run "Server_handler"
    [
      ( "make_sse_response",
        [
          test_case "basic" `Quick test_make_sse_response_basic;
          test_case "all_headers" `Quick test_make_sse_response_all_headers;
          test_case "extra_headers" `Quick test_make_sse_response_extra_headers;
          test_case "custom_status" `Quick test_make_sse_response_custom_status;
          test_case "body_content" `Quick test_make_sse_response_body_content;
        ] );
    ]
