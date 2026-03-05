type t =
  | Start
  | Start_step
  | Text_start of { id : string }
  | Text_delta of {
      id : string;
      text : string;
    }
  | Text_end of { id : string }
  | Reasoning_start of { id : string }
  | Reasoning_delta of {
      id : string;
      text : string;
    }
  | Reasoning_end of { id : string }
  | Tool_call of {
      tool_call_id : string;
      tool_name : string;
      args : Yojson.Safe.t;
    }
  | Tool_call_delta of {
      tool_call_id : string;
      tool_name : string;
      args_text_delta : string;
    }
  | Tool_result of {
      tool_call_id : string;
      tool_name : string;
      result : Yojson.Safe.t;
      is_error : bool;
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
    }
  | Error of { error : string }
