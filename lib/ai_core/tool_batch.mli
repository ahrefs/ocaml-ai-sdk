(** Running a step's tools one after another, keeping the results of the
    tools that returned before an abort. Internal to [ai_core]: [Ai_core]
    does not export this module. *)

type 'a t =
  | Completed of 'a list  (** Every item ran. The results are in order. *)
  | Aborted of 'a list
    (** The call's signal fired while an item ran, or before it started.
          Holds, in order, the results that [execute] returned before then.
          The other items have no result. *)

(** [run ~abort_signal f items] runs [f item ~execute] on each item in order.
    [f] passes the item's work, such as running a tool, to [execute] once,
    and does anything else, such as telemetry or emitting parts, around it.

    A result counts only if the work returned it before [abort_signal]
    fired: an item does not start once the signal has fired, and the signal
    cancels a running item, even one that ignores the signal. The batch
    keeps a result as soon as [execute] returns it, so an abort while [f]
    goes on afterwards does not drop it. Once the signal has fired, any failure of an
    item, an [Aborted] from another signal included, stops the batch with
    [Aborted]. Before that, a failure passes through. *)
val run :
  abort_signal:Ai_provider.Abort_signal.t option ->
  ('a -> execute:((unit -> 'b Lwt.t) -> 'b Lwt.t) -> unit Lwt.t) ->
  'a list ->
  'b t Lwt.t

(** The results the batch holds, whether it completed or not. *)
val results : 'a t -> 'a list
