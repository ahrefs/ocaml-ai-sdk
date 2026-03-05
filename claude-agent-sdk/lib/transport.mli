(** Subprocess transport: spawns Claude Code CLI, JSON I/O over stdio. *)

type t

(** Spawn the CLI subprocess with the given options and initial prompt.
    If [switch] is provided, the transport is cleaned up when the switch
    is turned off. *)
val create : ?switch:Lwt_switch.t -> options:Options.t -> prompt:string -> unit -> t Lwt.t

(** Write a JSON object as a line to stdin. Thread-safe via mutex. *)
val write_json : t -> Yojson.Safe.t -> unit Lwt.t

(** Close stdin to signal end of input. *)
val end_input : t -> unit Lwt.t

(** Stream of JSON objects from stdout. Ends when the process closes. *)
val read_stream : t -> Yojson.Safe.t Lwt_stream.t

(** Close stdin and wait for process exit. *)
val close : t -> Unix.process_status Lwt.t

(** PID of the child process. *)
val pid : t -> int
