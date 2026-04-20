type t = {
  request_timeout : float;
  stream_idle_timeout : float;
}

let default = { request_timeout = 600.0; stream_idle_timeout = 300.0 }

let validate ~name v =
  if Float.compare v 0.0 <= 0 then
    Printf.ksprintf invalid_arg "Http_timeouts.create: %s must be positive (got %f)" name v

let create ?(request_timeout = default.request_timeout) ?(stream_idle_timeout = default.stream_idle_timeout) () =
  validate ~name:"request_timeout" request_timeout;
  validate ~name:"stream_idle_timeout" stream_idle_timeout;
  { request_timeout; stream_idle_timeout }
