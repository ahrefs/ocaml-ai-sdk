(** {1 Chat Status} *)

type chat_status =
  | Submitted
  | Streaming
  | Ready
  | Error

(** {1 Message Role} *)

type role =
  | System
  | User
  | Assistant

(** {1 UI Message Parts} *)

type text_ui_part

module Text_part = struct
  type t = text_ui_part

  external text : t -> string = "text" [@@mel.get]
  external state : t -> string option = "state" [@@mel.get] [@@mel.return nullable]
end

type reasoning_ui_part

module Reasoning_part = struct
  type t = reasoning_ui_part

  external text : t -> string = "text" [@@mel.get]
  external state : t -> string option = "state" [@@mel.get] [@@mel.return nullable]
end

type tool_ui_part

module Tool_part = struct
  type t = tool_ui_part

  external tool_call_id : t -> string = "toolCallId" [@@mel.get]
  external state : t -> string = "state" [@@mel.get]
  external tool_name : t -> string option = "toolName" [@@mel.get] [@@mel.return nullable]
  external title : t -> string option = "title" [@@mel.get] [@@mel.return nullable]
  external input : t -> Js.Json.t option = "input" [@@mel.get] [@@mel.return nullable]
  external output : t -> Js.Json.t option = "output" [@@mel.get] [@@mel.return nullable]
  external error_text : t -> string option = "errorText" [@@mel.get] [@@mel.return nullable]
  external provider_executed : t -> bool option = "providerExecuted" [@@mel.get] [@@mel.return nullable]
end

type tool_approval

external tool_ui_part_approval : tool_ui_part -> tool_approval option = "approval" [@@mel.get] [@@mel.return nullable]
external tool_approval_id : tool_approval -> string = "id" [@@mel.get]

type source_url_ui_part

module Source_url_part = struct
  type t = source_url_ui_part

  external source_id : t -> string = "sourceId" [@@mel.get]
  external url : t -> string = "url" [@@mel.get]
  external title : t -> string option = "title" [@@mel.get] [@@mel.return nullable]
end

type source_document_ui_part

module Source_document_part = struct
  type t = source_document_ui_part

  external source_id : t -> string = "sourceId" [@@mel.get]
  external media_type : t -> string = "mediaType" [@@mel.get]
  external title : t -> string = "title" [@@mel.get]
  external filename : t -> string option = "filename" [@@mel.get] [@@mel.return nullable]
end

type file_ui_part

module File_part = struct
  type t = file_ui_part

  external media_type : t -> string = "mediaType" [@@mel.get]
  external url : t -> string = "url" [@@mel.get]
  external filename : t -> string option = "filename" [@@mel.get] [@@mel.return nullable]
end

type step_start_ui_part

type data_ui_part

external data_ui_part_data : data_ui_part -> Js.Json.t = "data" [@@mel.get]
external data_ui_part_id : data_ui_part -> string option = "id" [@@mel.get] [@@mel.return nullable]

external data_ui_part_type_raw : data_ui_part -> string = "type" [@@mel.get]

(** The data type name without the ["data-"] prefix.
    E.g. for a part with type ["data-weather"], returns ["weather"]. *)
let data_ui_part_data_type (part : data_ui_part) : string =
  let t = data_ui_part_type_raw part in
  if String.length t > 5 then String.sub t 5 (String.length t - 5) else t

type ui_message_part

external part_type : ui_message_part -> string = "type" [@@mel.get]

external as_text : ui_message_part -> text_ui_part = "%identity"
external as_reasoning : ui_message_part -> reasoning_ui_part = "%identity"
external as_tool_call : ui_message_part -> tool_ui_part = "%identity"
external as_source_url : ui_message_part -> source_url_ui_part = "%identity"
external as_source_document : ui_message_part -> source_document_ui_part = "%identity"
external as_file : ui_message_part -> file_ui_part = "%identity"
external as_step_start : ui_message_part -> step_start_ui_part = "%identity"
external as_data : ui_message_part -> data_ui_part = "%identity"

type classified_part =
  | Text of text_ui_part
  | Reasoning of reasoning_ui_part
  | Tool_call of tool_ui_part
  | Source_url of source_url_ui_part
  | Source_document of source_document_ui_part
  | File of file_ui_part
  | Step_start of step_start_ui_part
  | Data of data_ui_part
  | Unknown of string

let classify (part : ui_message_part) =
  let t = part_type part in
  let starts_with prefix = String.length t > String.length prefix && String.sub t 0 (String.length prefix) = prefix in
  match () with
  | () when String.equal t "text" -> Text (as_text part)
  | () when String.equal t "reasoning" -> Reasoning (as_reasoning part)
  | () when String.equal t "dynamic-tool" -> Tool_call (as_tool_call part)
  | () when starts_with "tool-" -> Tool_call (as_tool_call part)
  | () when String.equal t "source-url" -> Source_url (as_source_url part)
  | () when String.equal t "source-document" -> Source_document (as_source_document part)
  | () when String.equal t "file" -> File (as_file part)
  | () when String.equal t "step-start" -> Step_start (as_step_start part)
  | () when starts_with "data-" -> Data (as_data part)
  | () -> Unknown t

(** {1 UI Message} *)

type ui_message

module Message = struct
  type t = ui_message

  external id : t -> string = "id" [@@mel.get]
  external role_raw : t -> string = "role" [@@mel.get]
  external parts : t -> ui_message_part array = "parts" [@@mel.get]
  external metadata : t -> Js.Json.t option = "metadata" [@@mel.get] [@@mel.return nullable]

  let role (msg : t) : role =
    match role_raw msg with
    | "system" -> System
    | "user" -> User
    | "assistant" -> Assistant
    | _ -> User
end

(* Backwards-compatible top-level accessors *)
let ui_message_id = Message.id
let ui_message_role = Message.role
let ui_message_role_raw = Message.role_raw
let ui_message_parts = Message.parts
let ui_message_metadata = Message.metadata

(* Backwards-compatible part accessors *)
let text_ui_part_text = Text_part.text
let text_ui_part_state = Text_part.state
let reasoning_ui_part_text = Reasoning_part.text
let reasoning_ui_part_state = Reasoning_part.state
let tool_ui_part_tool_call_id = Tool_part.tool_call_id
let tool_ui_part_state = Tool_part.state
let tool_ui_part_tool_name = Tool_part.tool_name
let tool_ui_part_title = Tool_part.title
let tool_ui_part_input = Tool_part.input
let tool_ui_part_output = Tool_part.output
let tool_ui_part_error_text = Tool_part.error_text
let tool_ui_part_provider_executed = Tool_part.provider_executed
let source_url_ui_part_source_id = Source_url_part.source_id
let source_url_ui_part_url = Source_url_part.url
let source_url_ui_part_title = Source_url_part.title
let source_document_ui_part_source_id = Source_document_part.source_id
let source_document_ui_part_media_type = Source_document_part.media_type
let source_document_ui_part_title = Source_document_part.title
let source_document_ui_part_filename = Source_document_part.filename
let file_ui_part_media_type = File_part.media_type
let file_ui_part_url = File_part.url
let file_ui_part_filename = File_part.filename

(** {1 Chat Request Options} *)

type chat_request_options

external make_chat_request_options :
  ?headers:string Js.Dict.t -> ?body:Js.Json.t -> ?metadata:Js.Json.t -> unit -> chat_request_options = ""
[@@mel.obj]

(** {1 Error} *)

type error = Js.Exn.t
