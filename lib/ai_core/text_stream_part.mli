(** Events emitted by the fullStream during streaming text generation. *)

type t =
  | Start
  | Start_step
  | Text_start of { id : string }
  | Text_delta of {
      id : string;
      text : string;
    }
  | Text_end of { id : string }
  | Reasoning_start of {
      id : string;
      provider_metadata : Yojson.Basic.t option;
    }
  | Reasoning_delta of {
      id : string;
      text : string;
      provider_metadata : Yojson.Basic.t option;
    }
  | Reasoning_end of {
      id : string;
      provider_metadata : Yojson.Basic.t option;
    }
  | Tool_call of {
      tool_call_id : string;
      tool_name : string;
      args : Yojson.Basic.t;
    }
  | Tool_call_delta of {
      tool_call_id : string;
      tool_name : string;
      args_text_delta : string;
    }
  | Tool_result of {
      tool_call_id : string;
      tool_name : string;
      result : Yojson.Basic.t;
      is_error : bool;
      provider_metadata : Yojson.Basic.t option;
    }
  | Tool_output_denied of { tool_call_id : string }
  | Tool_approval_request of {
      approval_id : string;
      tool_call_id : string;
      tool_name : string;
      args : Yojson.Basic.t;
    }
  | Source of {
      source_id : string;
      url : string;
      title : string option;
    }
  | File of {
      url : string;
      media_type : string;
    }
  | Finish_step of {
      finish_reason : Ai_provider.Finish_reason.t;
      usage : Ai_provider.Usage.t;
    }
  | Finish of {
      finish_reason : Ai_provider.Finish_reason.t;
      usage : Ai_provider.Usage.t;
    }  (** The call finished. It is the last part of the stream. *)
  | Error of { error : exn }
    (** An error. When the call fails, it is the last part of the stream,
          and [error] is the exception the call failed with. A provider
          reports some errors inside a step's stream, as
          [Ai_provider.Provider_error.Provider_error], and those do not end
          the call: the step goes on, so more parts follow, such as its
          [Finish_step]. An [Error] part therefore does not say whether the
          call is over. [Stream_text_result.outcome] tells how the call
          ended. [Printexc.to_string error] is the text that
          [Stream_text_result.to_ui_message_stream] sends. *)
  | Abort of { reason : string option }
    (** The caller's abort signal fired. It is the last part of the stream:
          no [Finish_step] or [Finish] follows. [reason] is the signal's
          {!Ai_provider.Abort_signal.reason} as text, from [Printexc.to_string]. *)
