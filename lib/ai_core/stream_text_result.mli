(** Result of streaming text generation. *)

type t = {
  text_stream : string Lwt_stream.t;  (** Just the text deltas. *)
  full_stream : Text_stream_part.t Lwt_stream.t;  (** All events including tool calls, reasoning, finish. *)
  usage : Ai_provider.Usage.t Lwt.t;  (** Resolves when stream completes with aggregated usage. *)
  finish_reason : Ai_provider.Finish_reason.t Lwt.t;  (** Resolves when stream completes. *)
  steps : Generate_text_result.step list Lwt.t;  (** All steps, resolves when complete. *)
  warnings : Ai_provider.Warning.t list;
}

(** Transform the full stream into UIMessage protocol chunks
    for frontend consumption via SSE. *)
val to_ui_message_stream : ?message_id:string -> ?send_reasoning:bool -> t -> Ui_message_chunk.t Lwt_stream.t

(** Transform to SSE-encoded strings ready for HTTP response.
    Includes the [DONE] sentinel. *)
val to_ui_message_sse_stream : ?message_id:string -> ?send_reasoning:bool -> t -> string Lwt_stream.t
