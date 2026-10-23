(** Result of streaming text generation. *)

(** How a [stream_text] call ended. *)
type outcome =
  | Finished of Generate_text_result.t
    (** The call finished. The result is the one [on_finish] gets. Its
          [response] and [warnings] are empty, and with pending tool
          approvals and [max_steps:1] its finish reason can differ from what
          [generate_text] reports. *)
  | Aborted of {
      steps : Generate_text_result.step list;
      reason : exn option;
    }
    (** The abort signal fired. [steps] are the steps [on_abort] got, and
          [reason] is the signal's {!Ai_provider.Abort_signal.reason}. *)
  | Failed of exn
    (** The call failed with this exception, the one the result promises fail
          with. It is [Ai_provider.Abort_signal.Aborted] only when the
          model or a callback raised it while the call's signal had not
          fired, for example from a timeout of its own. A tool's own
          [Aborted] is its error result instead. *)

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
          [?output] with a schema was provided and parsing succeeds, [None] otherwise.
          Fails like [usage] when the call fails or is aborted. *)
  provider_metadata : Ai_provider.Provider_options.t option Lwt.t;
    (** Provider-specific metadata aggregated from all steps (typically the
        last step's metadata, e.g. Anthropic cache token counts). Resolves
        to [Some _] when at least one step's [Finish] chunk carried metadata,
        [None] otherwise. Fails like [usage] when the call fails or is
        aborted. Matches the [providerMetadata] promise on upstream's
        [StreamTextResult]. *)
  outcome : outcome Lwt.t;
    (** Resolves once the call has finished, failed or been aborted, after
          the other promises settle. It never fails. Use it to learn how the
          call ended: a failed call's [full_stream] ends with an [Error] part,
          but a provider error inside a step gives an [Error] part too and
          the step goes on, so an [Error] part does not mean the call is
          over. *)
}

(** Transform the full stream into UIMessage protocol chunks
    for frontend consumption via SSE. *)
val to_ui_message_stream : ?message_id:string -> ?send_reasoning:bool -> t -> Ui_message_chunk.t Lwt_stream.t

(** Transform to SSE-encoded strings ready for HTTP response.
    Includes the [DONE] sentinel. *)
val to_ui_message_sse_stream : ?message_id:string -> ?send_reasoning:bool -> t -> string Lwt_stream.t
