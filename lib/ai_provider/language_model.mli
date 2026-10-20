(** Core abstraction for AI language models.

    This is the OCaml equivalent of Vercel AI SDK's [LanguageModelV3].
    Each provider implements this signature. *)

(** The module type that every provider must implement. *)
module type S = sig
  (** Specification version, e.g. ["V3"]. *)
  val specification_version : string

  (** Provider identifier, e.g. ["anthropic"]. *)
  val provider : string

  (** Model identifier, e.g. ["claude-sonnet-4-6"]. *)
  val model_id : string

  (** Non-streaming generation. *)
  val generate : Call_options.t -> Generate_result.t Lwt.t

  (** Streaming generation. *)
  val stream : Call_options.t -> Stream_result.t Lwt.t
end

(** First-class module wrapper for runtime dispatch. *)
type t = (module S)

(** [generate] and [stream] dispatch to the model. A failure is always reported
    through the returned promise, never raised by the call itself. *)
val generate : t -> Call_options.t -> Generate_result.t Lwt.t

val stream : t -> Call_options.t -> Stream_result.t Lwt.t
val provider : t -> string
val model_id : t -> string
val specification_version : t -> string
