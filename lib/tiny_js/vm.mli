(** Client for one [tiny-js-sandbox] process, i.e. one QuickJS VM. Speaks the protocol of
    [lib/tiny-js-sandbox/PROTOCOL.md] over the child's stdio: spawning the process creates the VM, {!close} or {!kill}
    destroys it.

    A background reader resolves pending evals, forwards [host.post] messages and log frames, and, when the process
    dies or violates the protocol, fails every pending eval and ends the {!messages} stream. *)

type t

type payload =
  | Text of string
  | Bytes of string

type sandbox =
  | No_sandbox
  | Landlock
  | Seccomp
  | Full

(** Start the runner and perform the [hello] / [proto = 1] handshake (30 s timeout). Options map to the runner's CLI
    flags; omitted ones use the runner's defaults. [max_frame_bytes] is also the cap applied to frames read from and
    written to the runner. The runner's stderr is discarded. [on_log] receives [console.*] output and runner warnings
    ([level] is "log", "info", "debug", "warn" or "error"); exceptions it raises are ignored. On failure the process is
    killed and the error describes why (including its exit status).

    As a process-wide side effect, SIGPIPE is ignored so that writing to a dead runner yields an error. *)
val spawn :
  binary:string ->
  ?sandbox:sandbox ->
  memory_limit_mb:int ->
  ?cpu_seconds:int ->
  ?max_frame_bytes:int ->
  ?allow_clock:bool ->
  ?allow_random:bool ->
  ?on_log:(level:string -> string -> unit) ->
  unit ->
  (t, string) result Lwt.t

(** Evaluate [code] as a global script. [Ok None] is a JS [undefined]/[null] result, [Error _] a JS exception, a
    non-transferable result, a code string that is not valid UTF-8 or larger than the frame cap (the VM stays alive in
    those cases), or the death of the VM. Evals may run concurrently; the runner processes them in the order sent. *)
val eval : t -> string -> (payload option, string) result Lwt.t

(** Deliver a message to JS [host.onmessage].
    @raise Failure if the VM is dead or the write fails.
    @raise Invalid_argument if the frame exceeds the cap or a text payload is not valid UTF-8. *)
val send : t -> payload -> unit Lwt.t

(** Messages the VM sent with [host.post], in order. Ends when the VM dies or is closed. Single consumer; messages are
    buffered without bound until consumed. *)
val messages : t -> payload Lwt_stream.t

(** Close the runner's stdin, wait up to [grace_s] (default 2.0) seconds for it to exit, SIGKILL it otherwise, and
    return its exit status. Safe to call more than once. *)
val close : ?grace_s:float -> t -> Unix.process_status Lwt.t

(** SIGKILL the runner and wait for it. Pending evals fail. *)
val kill : t -> Unix.process_status Lwt.t

(** [false] once the reader has noticed the death of the process. *)
val is_alive : t -> bool
