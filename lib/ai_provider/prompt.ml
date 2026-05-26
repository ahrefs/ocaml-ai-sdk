type file_data =
  | Bytes of bytes
  | Base64 of string
  | Url of string

type user_part =
  | Text of {
      text : string;
      provider_options : Provider_options.t;
    }
  | File of {
      data : file_data;
      media_type : string;
      filename : string option;
      provider_options : Provider_options.t;
    }

type assistant_part =
  | Text of {
      text : string;
      provider_options : Provider_options.t;
    }
  | File of {
      data : file_data;
      media_type : string;
      filename : string option;
      provider_options : Provider_options.t;
    }
  | Reasoning of {
      text : string;
      provider_options : Provider_options.t;
    }
  | Tool_call of {
      id : string;
      name : string;
      args : Yojson.Basic.t;
      provider_options : Provider_options.t;
    }

type tool_result_content =
  | Result_text of string
  | Result_image of {
      data : string;
      media_type : string;
    }

type tool_result = {
  tool_call_id : string;
  tool_name : string;
  result : Yojson.Basic.t;
  is_error : bool;
  content : tool_result_content list;
  provider_options : Provider_options.t;
}

type message =
  | System of {
      content : string;
      provider_options : Provider_options.t;
    }
  | User of { content : user_part list }
  | Assistant of { content : assistant_part list }
  | Tool of { content : tool_result list }
