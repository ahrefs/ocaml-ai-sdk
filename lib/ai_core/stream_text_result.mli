(** Result of streaming text generation. *)

type t = {
  text_stream : string Lwt_stream.t;  (** Just the text deltas. *)
  full_stream : Text_stream_part.t Lwt_stream.t;  (** All events including tool calls, reasoning, finish. *)
  partial_output_stream : Yojson.Basic.t Lwt_stream.t;
    (** Parsed partial JSON objects as text accumulates.
          Only emits when [?output] with a schema is provided. *)
  usage : Ai_provider.Usage.t Lwt.t;  (** Resolves when stream completes with aggregated usage. *)
  finish_reason : Ai_provider.Finish_reason.t Lwt.t;  (** Resolves when stream completes. *)
  steps : Generate_text_result.step list Lwt.t;  (** All steps, resolves when complete. *)
  warnings : Ai_provider.Warning.t list;
  output : Yojson.Basic.t option Lwt.t;
    (** Final parsed and validated output. Resolves to [Some json] when
          [?output] with a schema was provided and parsing succeeds, [None] otherwise. *)
  provider_metadata : Ai_provider.Provider_options.t option Lwt.t;
    (** Provider-specific metadata aggregated from all steps (typically the
        last step's metadata, e.g. Anthropic cache token counts). Resolves
        to [Some _] when at least one step's [Finish] chunk carried metadata,
        [None] otherwise. Matches the [providerMetadata] promise on upstream's
        [StreamTextResult]. *)
}

(** Transform the full stream into UIMessage protocol chunks
    for frontend consumption via SSE. *)
val to_ui_message_stream : ?message_id:string -> ?send_reasoning:bool -> t -> Ui_message_chunk.t Lwt_stream.t

(** Transform to SSE-encoded strings ready for HTTP response.
    Includes the [DONE] sentinel. *)
val to_ui_message_sse_stream : ?message_id:string -> ?send_reasoning:bool -> t -> string Lwt_stream.t
