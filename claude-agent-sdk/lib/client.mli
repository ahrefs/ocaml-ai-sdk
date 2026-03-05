(** Stateful bidirectional client for multi-turn conversations. *)

type t

(** Create a new client. Does not connect yet.
    If [switch] is provided, all transports created by this client will be
    registered with it. When the switch is turned off, resources are cleaned
    up. A default switch is created if none is provided. *)
val create : ?switch:Lwt_switch.t -> ?options:Options.t -> unit -> t

(** Connect to Claude Code with an initial prompt. *)
val connect : t -> prompt:string -> unit Lwt.t

(** Send a follow-up prompt. Resumes the session if one exists. *)
val send_query : t -> prompt:string -> unit Lwt.t

(** Stream of all incoming messages. *)
val receive_messages : t -> Message.t Lwt_stream.t

(** Collect messages until a Result message arrives. *)
val receive_until_result : t -> Message.t list Lwt.t

(** Send an interrupt control request. *)
val interrupt : t -> unit Lwt.t

(** Change the permission mode mid-session. *)
val set_permission_mode : t -> Options.permission_mode -> unit Lwt.t

(** Change the model mid-session. *)
val set_model : t -> string -> unit Lwt.t

(** Current session ID, if established. *)
val session_id : t -> string option

(** Close the client and underlying transport. *)
val close : t -> unit Lwt.t

(** [with_client ~prompt f] creates a client, connects with [prompt],
    runs [f], then closes the client and turns off the switch. *)
val with_client : ?switch:Lwt_switch.t -> ?options:Options.t -> prompt:string -> (t -> 'a Lwt.t) -> 'a Lwt.t
