(** One-shot query: spawn a Claude Code session and stream typed messages. *)

(** Spawn a Claude Code session with the given prompt and return a stream
    of typed messages. The stream completes on a Result message or process
    exit. Transport is cleaned up automatically. If [switch] is provided,
    the transport is also cleaned up when the switch is turned off. *)
val run : prompt:string -> ?switch:Lwt_switch.t -> ?options:Options.t -> unit -> Message.t Lwt_stream.t Lwt.t
