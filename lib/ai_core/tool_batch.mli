(** Running a step's tools one after another, keeping the results of the
    tools that ran when an abort stops the batch. Internal to [ai_core]:
    [Ai_core] does not export this module. *)

type 'a t =
  | Completed of 'a list  (** Every item ran. The results are in order. *)
  | Aborted of 'a list
    (** An item failed with [Ai_provider.Abort_signal.Aborted] after the
          signal had fired. Holds the results of the items before it, in
          order. The items from that one on have no result. *)

(** [run ~abort_signal f items] runs [f] on each item in order, as
    [Lwt_list.map_s] does. When [f] fails with
    [Ai_provider.Abort_signal.Aborted] and [abort_signal] has fired, it skips
    the remaining items and returns [Aborted]. Any other failure, an
    [Aborted] from another signal included, passes through. *)
val run : abort_signal:Ai_provider.Abort_signal.t option -> ('a -> 'b Lwt.t) -> 'a list -> 'b t Lwt.t

(** The results the batch holds, whether it completed or not. *)
val results : 'a t -> 'a list

(** Fails with [Ai_provider.Abort_signal.Aborted], with the signal's reason,
    when an abort stopped the batch. Callers record the batch's step first. *)
val fail_if_aborted : abort_signal:Ai_provider.Abort_signal.t option -> 'a t -> unit Lwt.t
