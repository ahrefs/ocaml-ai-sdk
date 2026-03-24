(** Shared types for @ai-sdk/react bindings.

    @see <https://ai-sdk.dev> AI SDK documentation *)

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

val text_ui_part_text : text_ui_part -> string
val text_ui_part_state : text_ui_part -> string option

type reasoning_ui_part

val reasoning_ui_part_text : reasoning_ui_part -> string
val reasoning_ui_part_state : reasoning_ui_part -> string option

type tool_ui_part

val tool_ui_part_tool_call_id : tool_ui_part -> string
val tool_ui_part_state : tool_ui_part -> string
val tool_ui_part_tool_name : tool_ui_part -> string option
val tool_ui_part_title : tool_ui_part -> string option
val tool_ui_part_input : tool_ui_part -> Js.Json.t option
val tool_ui_part_output : tool_ui_part -> Js.Json.t option
val tool_ui_part_error_text : tool_ui_part -> string option
val tool_ui_part_provider_executed : tool_ui_part -> bool option

type source_url_ui_part

val source_url_ui_part_source_id : source_url_ui_part -> string
val source_url_ui_part_url : source_url_ui_part -> string
val source_url_ui_part_title : source_url_ui_part -> string option

type source_document_ui_part

val source_document_ui_part_source_id : source_document_ui_part -> string
val source_document_ui_part_media_type : source_document_ui_part -> string
val source_document_ui_part_title : source_document_ui_part -> string
val source_document_ui_part_filename : source_document_ui_part -> string option

type file_ui_part

val file_ui_part_media_type : file_ui_part -> string
val file_ui_part_url : file_ui_part -> string
val file_ui_part_filename : file_ui_part -> string option

type step_start_ui_part

type ui_message_part

val part_type : ui_message_part -> string
val as_text : ui_message_part -> text_ui_part
val as_reasoning : ui_message_part -> reasoning_ui_part
val as_tool_call : ui_message_part -> tool_ui_part
val as_source_url : ui_message_part -> source_url_ui_part
val as_source_document : ui_message_part -> source_document_ui_part
val as_file : ui_message_part -> file_ui_part
val as_step_start : ui_message_part -> step_start_ui_part

type classified_part =
  | Text of text_ui_part
  | Reasoning of reasoning_ui_part
  | Tool_call of tool_ui_part
  | Source_url of source_url_ui_part
  | Source_document of source_document_ui_part
  | File of file_ui_part
  | Step_start of step_start_ui_part
  | Unknown of string

(** Classify a message part into a typed variant.
    Matches both ["dynamic-tool"] and ["tool-*"] prefixed types as [Tool_call]. *)
val classify : ui_message_part -> classified_part

(** {1 UI Message} *)

type ui_message

val ui_message_id : ui_message -> string
val ui_message_role : ui_message -> role
val ui_message_role_raw : ui_message -> string
val ui_message_parts : ui_message -> ui_message_part array
val ui_message_metadata : ui_message -> Js.Json.t option

(** {1 Chat Request Options} *)

type chat_request_options

val make_chat_request_options :
  ?headers:string Js.Dict.t -> ?body:Js.Json.t -> ?metadata:Js.Json.t -> unit -> chat_request_options

(** {1 Error} *)

type error = Js.Exn.t
