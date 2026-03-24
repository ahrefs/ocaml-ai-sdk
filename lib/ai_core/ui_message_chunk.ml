type t =
  | Start of {
      message_id : string option;
      message_metadata : Yojson.Safe.t option;
    }
  | Finish of {
      finish_reason : Ai_provider.Finish_reason.t option;
      message_metadata : Yojson.Safe.t option;
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
      input : Yojson.Safe.t;
    }
  | Tool_output_available of {
      tool_call_id : string;
      output : Yojson.Safe.t;
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
  | Message_metadata of { message_metadata : Yojson.Safe.t }
  | Tool_input_error of {
      tool_call_id : string;
      tool_name : string;
      input : Yojson.Safe.t;
      error_text : string;
    }
  | Tool_output_denied of { tool_call_id : string }
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
      data : Yojson.Safe.t;
    }

(* JSON record types for serialization — field order matches wire format *)

type type_only_json = { type_ : string [@key "type"] } [@@deriving to_yojson]

type start_json = {
  type_ : string; [@key "type"]
  message_id : string option; [@key "messageId"] [@default None]
  message_metadata : Yojson.Safe.t option; [@key "messageMetadata"] [@default None]
}
[@@deriving to_yojson]

type finish_json = {
  type_ : string; [@key "type"]
  finish_reason : string option; [@key "finishReason"] [@default None]
  message_metadata : Yojson.Safe.t option; [@key "messageMetadata"] [@default None]
}
[@@deriving to_yojson]

type abort_json = {
  type_ : string; [@key "type"]
  reason : string option; [@default None]
}
[@@deriving to_yojson]

type id_json = {
  type_ : string; [@key "type"]
  id : string;
}
[@@deriving to_yojson]

type id_delta_json = {
  type_ : string; [@key "type"]
  id : string;
  delta : string;
}
[@@deriving to_yojson]

type tool_input_start_json = {
  type_ : string; [@key "type"]
  tool_call_id : string; [@key "toolCallId"]
  tool_name : string; [@key "toolName"]
}
[@@deriving to_yojson]

type tool_input_delta_json = {
  type_ : string; [@key "type"]
  tool_call_id : string; [@key "toolCallId"]
  input_text_delta : string; [@key "inputTextDelta"]
}
[@@deriving to_yojson]

type tool_input_available_json = {
  type_ : string; [@key "type"]
  tool_call_id : string; [@key "toolCallId"]
  tool_name : string; [@key "toolName"]
  input : Yojson.Safe.t;
}
[@@deriving to_yojson]

type tool_output_available_json = {
  type_ : string; [@key "type"]
  tool_call_id : string; [@key "toolCallId"]
  output : Yojson.Safe.t;
}
[@@deriving to_yojson]

type tool_output_error_json = {
  type_ : string; [@key "type"]
  tool_call_id : string; [@key "toolCallId"]
  error_text : string; [@key "errorText"]
}
[@@deriving to_yojson]

type source_url_json = {
  type_ : string; [@key "type"]
  source_id : string; [@key "sourceId"]
  url : string;
  title : string option; [@default None]
}
[@@deriving to_yojson]

type file_json = {
  type_ : string; [@key "type"]
  url : string;
  media_type : string; [@key "mediaType"]
}
[@@deriving to_yojson]

type message_metadata_json = {
  type_ : string; [@key "type"]
  message_metadata : Yojson.Safe.t; [@key "messageMetadata"]
}
[@@deriving to_yojson]

type tool_input_error_json = {
  type_ : string; [@key "type"]
  tool_call_id : string; [@key "toolCallId"]
  tool_name : string; [@key "toolName"]
  input : Yojson.Safe.t;
  error_text : string; [@key "errorText"]
}
[@@deriving to_yojson]

type tool_output_denied_json = {
  type_ : string; [@key "type"]
  tool_call_id : string; [@key "toolCallId"]
}
[@@deriving to_yojson]

type source_document_json = {
  type_ : string; [@key "type"]
  source_id : string; [@key "sourceId"]
  media_type : string; [@key "mediaType"]
  title : string;
  filename : string option; [@default None]
}
[@@deriving to_yojson]

type error_json = {
  type_ : string; [@key "type"]
  error_text : string; [@key "errorText"]
}
[@@deriving to_yojson]

type data_json = {
  type_ : string; [@key "type"]
  id : string option; [@default None]
  data : Yojson.Safe.t;
}
[@@deriving to_yojson]

let to_yojson = function
  | Start { message_id; message_metadata } ->
    start_json_to_yojson { type_ = "start"; message_id; message_metadata }
  | Finish { finish_reason; message_metadata } ->
    finish_json_to_yojson
      {
        type_ = "finish";
        finish_reason = Option.map Ai_provider.Finish_reason.to_string finish_reason;
        message_metadata;
      }
  | Abort { reason } -> abort_json_to_yojson { type_ = "abort"; reason }
  | Start_step -> type_only_json_to_yojson { type_ = "start-step" }
  | Finish_step -> type_only_json_to_yojson { type_ = "finish-step" }
  | Text_start { id } -> id_json_to_yojson { type_ = "text-start"; id }
  | Text_delta { id; delta } -> id_delta_json_to_yojson { type_ = "text-delta"; id; delta }
  | Text_end { id } -> id_json_to_yojson { type_ = "text-end"; id }
  | Reasoning_start { id } -> id_json_to_yojson { type_ = "reasoning-start"; id }
  | Reasoning_delta { id; delta } -> id_delta_json_to_yojson { type_ = "reasoning-delta"; id; delta }
  | Reasoning_end { id } -> id_json_to_yojson { type_ = "reasoning-end"; id }
  | Tool_input_start { tool_call_id; tool_name } ->
    tool_input_start_json_to_yojson { type_ = "tool-input-start"; tool_call_id; tool_name }
  | Tool_input_delta { tool_call_id; input_text_delta } ->
    tool_input_delta_json_to_yojson { type_ = "tool-input-delta"; tool_call_id; input_text_delta }
  | Tool_input_available { tool_call_id; tool_name; input } ->
    tool_input_available_json_to_yojson { type_ = "tool-input-available"; tool_call_id; tool_name; input }
  | Tool_output_available { tool_call_id; output } ->
    tool_output_available_json_to_yojson { type_ = "tool-output-available"; tool_call_id; output }
  | Tool_output_error { tool_call_id; error_text } ->
    tool_output_error_json_to_yojson { type_ = "tool-output-error"; tool_call_id; error_text }
  | Source_url { source_id; url; title } ->
    source_url_json_to_yojson { type_ = "source-url"; source_id; url; title }
  | File { url; media_type } -> file_json_to_yojson { type_ = "file"; url; media_type }
  | Message_metadata { message_metadata } ->
    message_metadata_json_to_yojson { type_ = "message-metadata"; message_metadata }
  | Tool_input_error { tool_call_id; tool_name; input; error_text } ->
    tool_input_error_json_to_yojson { type_ = "tool-input-error"; tool_call_id; tool_name; input; error_text }
  | Tool_output_denied { tool_call_id } ->
    tool_output_denied_json_to_yojson { type_ = "tool-output-denied"; tool_call_id }
  | Source_document { source_id; media_type; title; filename } ->
    source_document_json_to_yojson { type_ = "source-document"; source_id; media_type; title; filename }
  | Error { error_text } -> error_json_to_yojson { type_ = "error"; error_text }
  | Data { data_type; id; data } ->
    data_json_to_yojson { type_ = Printf.sprintf "data-%s" data_type; id; data }
