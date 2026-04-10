let headers =
  [
    "content-type", "text/event-stream";
    "cache-control", "no-cache";
    "connection", "keep-alive";
    "x-vercel-ai-ui-message-stream", "v1";
    "x-accel-buffering", "no";
  ]

let chunk_to_sse chunk =
  let json = Ui_message_chunk.to_json chunk in
  Printf.sprintf "data: %s\n\n" (Yojson.Basic.to_string json)

let done_sse = "data: [DONE]\n\n"

let stream_to_sse chunks =
  let sse_stream, push = Lwt_stream.create () in
  Lwt.async (fun () ->
    try%lwt
      let%lwt () = Lwt_stream.iter (fun chunk -> push (Some (chunk_to_sse chunk))) chunks in
      push (Some done_sse);
      push None;
      Lwt.return_unit
    with _exn ->
      push (Some done_sse);
      push None;
      Lwt.return_unit);
  sse_stream
