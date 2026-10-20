type t = {
  connect_timeout : float;
  request_timeout : float;
  stream_idle_timeout : float;
}

let default = { connect_timeout = 10.0; request_timeout = 600.0; stream_idle_timeout = 300.0 }

let validate ~name v =
  if Float.compare v 0.0 <= 0 then
    Printf.ksprintf invalid_arg "Http_timeouts.create: %s must be positive (got %f)" name v

let create ?(connect_timeout = default.connect_timeout) ?(request_timeout = default.request_timeout)
  ?(stream_idle_timeout = default.stream_idle_timeout) () =
  validate ~name:"connect_timeout" connect_timeout;
  validate ~name:"request_timeout" request_timeout;
  validate ~name:"stream_idle_timeout" stream_idle_timeout;
  { connect_timeout; request_timeout; stream_idle_timeout }
