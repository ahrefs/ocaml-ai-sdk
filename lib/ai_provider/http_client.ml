type head = {
  status : int;
  headers : (string * string) list;
}

type header_state =
  | Collecting of (string * string) list
  | Delivered

type header_line =
  | Status_line
  | End_of_headers
  | Field of (string * string)
  | Ignored

type pending = {
  transfer : Curl.curlCode Lwt.t;
  head_ready : (head, Curl.curlCode) result Lwt_mvar.t;
  chunks : string Lwt_stream.t;
  error_detail : string ref;
}

type response = {
  head : head;
  pending : pending;
  timeouts : Http_timeouts.t;
  provider : string;
}

(* curl_lwt hands back libcurl's raw result code, which can be newer than
   ocurl's curlCode constructors, so codes are only ever compared as integers. *)
let code_number = Curl.int_of_curlCode
let curle_ok = code_number Curl.CURLE_OK
let curle_http2 = 16
let curle_http2_stream = 92

let transient_codes =
  curle_http2
  :: curle_http2_stream
  :: List.map code_number
       Curl.
         [
           CURLE_COULDNT_RESOLVE_HOST;
           CURLE_COULDNT_CONNECT;
           CURLE_PARTIAL_FILE;
           CURLE_OPERATION_TIMEOUTED;
           CURLE_SSL_CONNECT_ERROR;
           CURLE_GOT_NOTHING;
           CURLE_SEND_ERROR;
           CURLE_RECV_ERROR;
         ]

let succeeded code = Int.equal (code_number code) curle_ok
let status r = r.head.status
let header r name = List.assoc_opt (String.lowercase_ascii name) r.head.headers

let classify_header_line line =
  match String.trim line with
  | "" -> End_of_headers
  | line when String.starts_with ~prefix:"HTTP/" line -> Status_line
  | line ->
  match String.index_opt line ':' with
  | Some i ->
    let name = String.lowercase_ascii (String.trim (String.sub line 0 i)) in
    let value = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
    Field (name, value)
  | None -> Ignored

let deliver ~state ~head_ready result =
  match !state with
  | Delivered -> ()
  | Collecting _ ->
    state := Delivered;
    ignore (Lwt_mvar.put head_ready result : unit Lwt.t)

let on_header_line ~handle ~state ~head_ready line =
  (match !state, classify_header_line line with
  | Delivered, (Status_line | End_of_headers | Field _ | Ignored) -> ()
  | Collecting _, Status_line -> state := Collecting []
  | Collecting fields, Field field -> state := Collecting (field :: fields)
  | Collecting _, Ignored -> ()
  | Collecting fields, End_of_headers ->
  match Curl.get_responsecode handle with
  | status when status >= 200 -> deliver ~state ~head_ready (Ok { status; headers = List.rev fields })
  | _informational -> state := Collecting []);
  String.length line

let header_line (name, value) =
  match value with
  | "" -> name ^ ";"
  | value -> Printf.sprintf "%s: %s" name value

let configure handle ~url ~headers ~body ~error_detail ~on_header ~on_chunk =
  Curl.set_url handle url;
  Curl.set_postfields handle body;
  Curl.set_postfieldsize handle (String.length body);
  (* An empty Expect header stops libcurl from waiting for 100-continue on large bodies. *)
  Curl.set_httpheader handle (List.map header_line headers @ [ "Expect:" ]);
  Curl.set_nosignal handle true;
  Curl.set_errorbuffer handle error_detail;
  Curl.set_headerfunction handle on_header;
  Curl.set_writefunction handle on_chunk

let start ~url ~headers ~body =
  let handle = Curl.init () in
  let head_ready = Lwt_mvar.create_empty () in
  let chunks, push = Lwt_stream.create () in
  let state = ref (Collecting []) in
  let error_detail = ref "" in
  let on_chunk data =
    push (Some data);
    String.length data
  in
  match
    configure handle ~url ~headers ~body ~error_detail ~on_header:(on_header_line ~handle ~state ~head_ready) ~on_chunk;
    Curl_lwt.perform handle
  with
  | exception exn ->
    Curl.cleanup handle;
    raise exn
  | transfer ->
    let release () =
      Curl.cleanup handle;
      push None
    in
    (* Lwt runs curl_lwt's on_cancel, which detaches the handle from the multi,
       before regular callbacks, so cleanup never frees an attached handle. *)
    Lwt.on_any transfer
      (fun code ->
        release ();
        deliver ~state ~head_ready (Error (if succeeded code then Curl.CURLE_GOT_NOTHING else code)))
      (fun (_ : exn) -> release ());
    { transfer; head_ready; chunks; error_detail }

let network_error ~provider (pending : pending) code =
  let message =
    match !(pending.error_detail) with
    | "" -> Curl.strerror code
    | detail -> detail
  in
  let is_retryable = List.exists (Int.equal (code_number code)) transient_codes in
  Provider_error.Provider_error { provider; kind = Network_error { message }; is_retryable; retry_after_s = None }

(* Curl data arrives inside libcurl callbacks, where libcurl rejects API calls
   such as starting another transfer. The pause moves downstream code to the
   next main-loop iteration. *)
let outside_curl_callback promise =
  let%lwt value = promise in
  let%lwt () = Lwt.pause () in
  Lwt.return value

let await_head ~(timeouts : Http_timeouts.t) ~provider (pending : pending) =
  let started = Unix.gettimeofday () in
  match%lwt
    outside_curl_callback (Lwt_unix.with_timeout timeouts.request_timeout (fun () -> Lwt_mvar.take pending.head_ready))
  with
  | Ok head -> Lwt.return head
  | Error code -> Lwt.fail (network_error ~provider pending code)
  | exception Lwt_unix.Timeout ->
    Lwt.cancel pending.transfer;
    let elapsed_s = Unix.gettimeofday () -. started in
    let err =
      Provider_error.make_timeout ~provider ~phase:Request_headers ~elapsed_s ~limit_s:timeouts.request_timeout
    in
    Lwt.fail (Provider_error.Provider_error err)
  | exception exn ->
    Lwt.cancel pending.transfer;
    Lwt.fail exn

let post ~timeouts ~provider ~headers ~body url =
  let%lwt pending = Lwt.wrap (fun () -> start ~url ~headers ~body) in
  let%lwt head = await_head ~timeouts ~provider pending in
  Lwt.return { head; pending; timeouts; provider }

let response_of_chunks ~timeouts ~provider ~status ~headers chunks =
  let headers = List.map (fun (name, value) -> String.lowercase_ascii name, value) headers in
  let pending =
    { transfer = Lwt.return Curl.CURLE_OK; head_ready = Lwt_mvar.create_empty (); chunks; error_detail = ref "" }
  in
  { head = { status; headers }; pending; timeouts; provider }

let next_chunk r =
  outside_curl_callback
    (Lwt.pick
       [
         (let%lwt chunk = Lwt_stream.get r.pending.chunks in
          Lwt.return (`Chunk chunk));
         (let%lwt () = Lwt_unix.sleep r.timeouts.stream_idle_timeout in
          Lwt.return `Idle);
       ])

let transfer_result r =
  let%lwt code = r.pending.transfer in
  if succeeded code then Lwt.return_unit else Lwt.fail (network_error ~provider:r.provider r.pending code)

let iter_chunks r ~f =
  let rec loop () =
    match%lwt next_chunk r with
    | `Chunk (Some chunk) ->
      f chunk;
      loop ()
    | `Chunk None -> transfer_result r
    | `Idle ->
      let limit_s = r.timeouts.stream_idle_timeout in
      let err = Provider_error.make_timeout ~provider:r.provider ~phase:Stream_idle ~elapsed_s:limit_s ~limit_s in
      Lwt.fail (Provider_error.Provider_error err)
  in
  try%lwt loop ()
  with exn ->
    Lwt.cancel r.pending.transfer;
    Lwt.fail exn

let body_string r =
  let buf = Buffer.create 4096 in
  let%lwt () = iter_chunks r ~f:(Buffer.add_string buf) in
  Lwt.return (Buffer.contents buf)

let split_on_newlines buf chunk push =
  String.iter
    (function
      | '\n' ->
        push (Some (Buffer.contents buf));
        Buffer.clear buf
      | '\r' -> ()
      | c -> Buffer.add_char buf c)
    chunk

let body_lines r =
  let buf = Buffer.create 256 in
  let lines, push = Lwt_stream.create () in
  Lwt.async (fun () ->
    try%lwt
      let%lwt () = iter_chunks r ~f:(fun chunk -> split_on_newlines buf chunk push) in
      if Buffer.length buf > 0 then push (Some (Buffer.contents buf));
      push None;
      Lwt.return_unit
    with exn ->
      push None;
      Lwt.fail exn);
  lines
