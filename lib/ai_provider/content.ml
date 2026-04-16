type t =
  | Text of { text : string }
  | Tool_call of {
      tool_call_type : string;
      tool_call_id : string;
      tool_name : string;
      args : string;
    }
  | Reasoning of {
      text : string;
      signature : string option;
      provider_options : Provider_options.t;
    }
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
