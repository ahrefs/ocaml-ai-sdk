(** UIMessage stream protocol chunk types.

    These are the events sent over SSE to the frontend.
    JSON field names use camelCase to match the Vercel AI SDK wire format.
    See: https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol *)

type t =
  | Start of {
      message_id : string option;
      message_metadata : Yojson.Basic.t option;
    }
  | Finish of {
      finish_reason : Ai_provider.Finish_reason.t option;
      message_metadata : Yojson.Basic.t option;
    }
  | Abort of { reason : string option }
  | Start_step
  | Finish_step
  | Text_start of { id : string }
  | Text_delta of {
      id : string;
      delta : string;
    }
  | Text_end of { id : string }
  | Reasoning_start of { id : string }
  | Reasoning_delta of {
      id : string;
      delta : string;
    }
  | Reasoning_end of { id : string }
  | Tool_input_start of {
      tool_call_id : string;
      tool_name : string;
    }
  | Tool_input_delta of {
      tool_call_id : string;
      input_text_delta : string;
    }
  | Tool_input_available of {
      tool_call_id : string;
      tool_name : string;
      input : Yojson.Basic.t;
    }
  | Tool_output_available of {
      tool_call_id : string;
      output : Yojson.Basic.t;
    }
  | Tool_output_error of {
      tool_call_id : string;
      error_text : string;
    }
  | Source_url of {
      source_id : string;
      url : string;
      title : string option;
    }
  | File of {
      url : string;
      media_type : string;
    }
  | Message_metadata of { message_metadata : Yojson.Basic.t }
  | Tool_input_error of {
      tool_call_id : string;
      tool_name : string;
      input : Yojson.Basic.t;
      error_text : string;
    }
  | Tool_output_denied of { tool_call_id : string }
  | Tool_approval_request of {
      approval_id : string;
      tool_call_id : string;
    }
  | Source_document of {
      source_id : string;
      media_type : string;
      title : string;
      filename : string option;
    }
  | Error of { error_text : string }
  | Data of {
      data_type : string;
      id : string option;
      data : Yojson.Basic.t;
    }

(** Serialize to JSON with camelCase field names matching the Vercel AI SDK. *)
val to_json : t -> Yojson.Basic.t
