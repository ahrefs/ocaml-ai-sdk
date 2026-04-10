open Melange_json.Primitives

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
      provider_metadata : Yojson.Basic.t option;
    }
  | Tool_output_error of {
      tool_call_id : string;
      error_text : string;
      provider_metadata : Yojson.Basic.t option;
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

(* JSON record types for serialization — field order matches wire format *)

type type_only_json = { type_ : string [@json.key "type"] } [@@deriving to_json]

type start_json = {
  type_ : string; [@json.key "type"]
  message_id : string option; [@json.key "messageId"] [@json.option] [@json.drop_default]
  message_metadata : Melange_json.t option; [@json.key "messageMetadata"] [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type finish_json = {
  type_ : string; [@json.key "type"]
  finish_reason : string option; [@json.key "finishReason"] [@json.option] [@json.drop_default]
  message_metadata : Melange_json.t option; [@json.key "messageMetadata"] [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type abort_json = {
  type_ : string; [@json.key "type"]
  reason : string option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type id_json = {
  type_ : string; [@json.key "type"]
  id : string;
}
[@@deriving to_json]

type id_delta_json = {
  type_ : string; [@json.key "type"]
  id : string;
  delta : string;
}
[@@deriving to_json]

type tool_input_start_json = {
  type_ : string; [@json.key "type"]
  tool_call_id : string; [@json.key "toolCallId"]
  tool_name : string; [@json.key "toolName"]
}
[@@deriving to_json]

type tool_input_delta_json = {
  type_ : string; [@json.key "type"]
  tool_call_id : string; [@json.key "toolCallId"]
  input_text_delta : string; [@json.key "inputTextDelta"]
}
[@@deriving to_json]

type tool_input_available_json = {
  type_ : string; [@json.key "type"]
  tool_call_id : string; [@json.key "toolCallId"]
  tool_name : string; [@json.key "toolName"]
  input : Melange_json.t;
}
[@@deriving to_json]

type tool_output_available_json = {
  type_ : string; [@json.key "type"]
  tool_call_id : string; [@json.key "toolCallId"]
  output : Melange_json.t;
  provider_metadata : Melange_json.t option; [@json.key "providerMetadata"] [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type tool_output_error_json = {
  type_ : string; [@json.key "type"]
  tool_call_id : string; [@json.key "toolCallId"]
  error_text : string; [@json.key "errorText"]
  provider_metadata : Melange_json.t option; [@json.key "providerMetadata"] [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type tool_approval_request_json = {
  type_ : string; [@json.key "type"]
  approval_id : string; [@json.key "approvalId"]
  tool_call_id : string; [@json.key "toolCallId"]
}
[@@deriving to_json]

type source_url_json = {
  type_ : string; [@json.key "type"]
  source_id : string; [@json.key "sourceId"]
  url : string;
  title : string option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type file_json = {
  type_ : string; [@json.key "type"]
  url : string;
  media_type : string; [@json.key "mediaType"]
}
[@@deriving to_json]

type message_metadata_json = {
  type_ : string; [@json.key "type"]
  message_metadata : Melange_json.t; [@json.key "messageMetadata"]
}
[@@deriving to_json]

type tool_input_error_json = {
  type_ : string; [@json.key "type"]
  tool_call_id : string; [@json.key "toolCallId"]
  tool_name : string; [@json.key "toolName"]
  input : Melange_json.t;
  error_text : string; [@json.key "errorText"]
}
[@@deriving to_json]

type tool_output_denied_json = {
  type_ : string; [@json.key "type"]
  tool_call_id : string; [@json.key "toolCallId"]
}
[@@deriving to_json]

type source_document_json = {
  type_ : string; [@json.key "type"]
  source_id : string; [@json.key "sourceId"]
  media_type : string; [@json.key "mediaType"]
  title : string;
  filename : string option; [@json.option] [@json.drop_default]
}
[@@deriving to_json]

type error_json = {
  type_ : string; [@json.key "type"]
  error_text : string; [@json.key "errorText"]
}
[@@deriving to_json]

type data_json = {
  type_ : string; [@json.key "type"]
  id : string option; [@json.option] [@json.drop_default]
  data : Melange_json.t;
}
[@@deriving to_json]

let to_json = function
  | Start { message_id; message_metadata } -> start_json_to_json { type_ = "start"; message_id; message_metadata }
  | Finish { finish_reason; message_metadata } ->
    finish_json_to_json
      {
        type_ = "finish";
        finish_reason = Option.map Ai_provider.Finish_reason.to_string finish_reason;
        message_metadata;
      }
  | Abort { reason } -> abort_json_to_json { type_ = "abort"; reason }
  | Start_step -> type_only_json_to_json { type_ = "start-step" }
  | Finish_step -> type_only_json_to_json { type_ = "finish-step" }
  | Text_start { id } -> id_json_to_json { type_ = "text-start"; id }
  | Text_delta { id; delta } -> id_delta_json_to_json { type_ = "text-delta"; id; delta }
  | Text_end { id } -> id_json_to_json { type_ = "text-end"; id }
  | Reasoning_start { id } -> id_json_to_json { type_ = "reasoning-start"; id }
  | Reasoning_delta { id; delta } -> id_delta_json_to_json { type_ = "reasoning-delta"; id; delta }
  | Reasoning_end { id } -> id_json_to_json { type_ = "reasoning-end"; id }
  | Tool_input_start { tool_call_id; tool_name } ->
    tool_input_start_json_to_json { type_ = "tool-input-start"; tool_call_id; tool_name }
  | Tool_input_delta { tool_call_id; input_text_delta } ->
    tool_input_delta_json_to_json { type_ = "tool-input-delta"; tool_call_id; input_text_delta }
  | Tool_input_available { tool_call_id; tool_name; input } ->
    tool_input_available_json_to_json { type_ = "tool-input-available"; tool_call_id; tool_name; input }
  | Tool_output_available { tool_call_id; output; provider_metadata } ->
    tool_output_available_json_to_json { type_ = "tool-output-available"; tool_call_id; output; provider_metadata }
  | Tool_output_error { tool_call_id; error_text; provider_metadata } ->
    tool_output_error_json_to_json { type_ = "tool-output-error"; tool_call_id; error_text; provider_metadata }
  | Source_url { source_id; url; title } -> source_url_json_to_json { type_ = "source-url"; source_id; url; title }
  | File { url; media_type } -> file_json_to_json { type_ = "file"; url; media_type }
  | Message_metadata { message_metadata } ->
    message_metadata_json_to_json { type_ = "message-metadata"; message_metadata }
  | Tool_input_error { tool_call_id; tool_name; input; error_text } ->
    tool_input_error_json_to_json { type_ = "tool-input-error"; tool_call_id; tool_name; input; error_text }
  | Tool_output_denied { tool_call_id } ->
    tool_output_denied_json_to_json { type_ = "tool-output-denied"; tool_call_id }
  | Tool_approval_request { approval_id; tool_call_id } ->
    tool_approval_request_json_to_json { type_ = "tool-approval-request"; approval_id; tool_call_id }
  | Source_document { source_id; media_type; title; filename } ->
    source_document_json_to_json { type_ = "source-document"; source_id; media_type; title; filename }
  | Error { error_text } -> error_json_to_json { type_ = "error"; error_text }
  | Data { data_type; id; data } -> data_json_to_json { type_ = Printf.sprintf "data-%s" data_type; id; data }
