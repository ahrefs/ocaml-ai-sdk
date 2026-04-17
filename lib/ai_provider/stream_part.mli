(** Individual parts emitted during streaming generation. *)

type t =
  | Stream_start of { warnings : Warning.t list }
  | Text of { text : string }
  | Reasoning of {
      text : string;
      signature : string option;
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
    }
  | Error of { error : Provider_error.t }
  | Provider_metadata of { metadata : Provider_options.t }
