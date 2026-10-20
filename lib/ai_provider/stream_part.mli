(** Individual parts emitted during streaming generation. *)

type t =
  | Stream_start of { warnings : Warning.t list }
  | Text of { text : string }
  | Reasoning of {
      text : string;
      signature : string option;
      provider_options : Provider_options.t;
    }
  | Tool_call_delta of {
      tool_call_type : string;
      tool_call_id : string;
      tool_name : string;
      args_text_delta : string;
    }
  | Tool_call_finish of { tool_call_id : string }
  | File of {
      data : bytes;
      media_type : string;
    }
  | Source of {
      source_type : string;
      id : string;
      url : string;
      title : string option;
      provider_options : Provider_options.t;
    }
  | Finish of {
      finish_reason : Finish_reason.t;
      usage : Usage.t;
      provider_metadata : Provider_options.t option;
        (** Provider-specific metadata available after the stream finishes
              (e.g. Anthropic cache_creation_input / cache_read_input token
              counts). Matches the [providerMetadata] field on upstream's
              [finish] LanguageModelV4StreamPart. *)
    }
  | Error of { error : Provider_error.t }

(** [pump ~provider ~push f events] runs [f] on each event in the background,
    then closes the output with [push None], whatever happens.

    When [f] fails to decode an event's JSON, a non-retryable
    [Deserialization_error] carrying the event's data is pushed and the next
    event is processed. Any other exception, raised by [events] or by [f], is
    pushed as an [Error] part and ends the stream: a [Provider_error] as is,
    anything else as a [Deserialization_error]. *)
val pump : provider:string -> push:(t option -> unit) -> (Sse.event -> unit) -> Sse.event Lwt_stream.t -> unit
