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

external text_ui_part_text : text_ui_part -> string = "text" [@@mel.get]

external text_ui_part_state : text_ui_part -> string option = "state" [@@mel.get] [@@mel.return nullable]

type reasoning_ui_part

external reasoning_ui_part_text : reasoning_ui_part -> string = "text" [@@mel.get]

external reasoning_ui_part_state : reasoning_ui_part -> string option = "state" [@@mel.get] [@@mel.return nullable]

type tool_ui_part

external tool_ui_part_tool_call_id : tool_ui_part -> string = "toolCallId" [@@mel.get]
external tool_ui_part_state : tool_ui_part -> string = "state" [@@mel.get]

external tool_ui_part_tool_name : tool_ui_part -> string option = "toolName" [@@mel.get] [@@mel.return nullable]

external tool_ui_part_title : tool_ui_part -> string option = "title" [@@mel.get] [@@mel.return nullable]

external tool_ui_part_input : tool_ui_part -> Js.Json.t option = "input" [@@mel.get] [@@mel.return nullable]

external tool_ui_part_output : tool_ui_part -> Js.Json.t option = "output" [@@mel.get] [@@mel.return nullable]

external tool_ui_part_error_text : tool_ui_part -> string option = "errorText" [@@mel.get] [@@mel.return nullable]

external tool_ui_part_provider_executed : tool_ui_part -> bool option = "providerExecuted"
[@@mel.get] [@@mel.return nullable]

type source_url_ui_part

external source_url_ui_part_source_id : source_url_ui_part -> string = "sourceId" [@@mel.get]
external source_url_ui_part_url : source_url_ui_part -> string = "url" [@@mel.get]

external source_url_ui_part_title : source_url_ui_part -> string option = "title" [@@mel.get] [@@mel.return nullable]

type source_document_ui_part

external source_document_ui_part_source_id : source_document_ui_part -> string = "sourceId" [@@mel.get]

external source_document_ui_part_media_type : source_document_ui_part -> string = "mediaType" [@@mel.get]

external source_document_ui_part_title : source_document_ui_part -> string = "title" [@@mel.get]

external source_document_ui_part_filename : source_document_ui_part -> string option = "filename"
[@@mel.get] [@@mel.return nullable]

type file_ui_part

external file_ui_part_media_type : file_ui_part -> string = "mediaType" [@@mel.get]
external file_ui_part_url : file_ui_part -> string = "url" [@@mel.get]

external file_ui_part_filename : file_ui_part -> string option = "filename" [@@mel.get] [@@mel.return nullable]

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

external ui_message_id : ui_message -> string = "id" [@@mel.get]
external ui_message_role_raw : ui_message -> string = "role" [@@mel.get]
external ui_message_parts : ui_message -> ui_message_part array = "parts" [@@mel.get]

external ui_message_metadata : ui_message -> Js.Json.t option = "metadata" [@@mel.get] [@@mel.return nullable]

let ui_message_role (msg : ui_message) : role =
  match ui_message_role_raw msg with
  | "system" -> System
  | "user" -> User
  | "assistant" -> Assistant
  | _ -> User

(** {1 Chat Request Options} *)

type chat_request_options

external make_chat_request_options :
  ?headers:string Js.Dict.t -> ?body:Js.Json.t -> ?metadata:Js.Json.t -> unit -> chat_request_options = ""
[@@mel.obj]

(** {1 Error} *)

type error = Js.Exn.t
