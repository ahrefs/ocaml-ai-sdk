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

(** Text content part. *)
module Text_part : sig
  type t = text_ui_part

  val text : t -> string
  val state : t -> string option
end

type reasoning_ui_part

(** Reasoning / thinking content part. *)
module Reasoning_part : sig
  type t = reasoning_ui_part

  val text : t -> string
  val state : t -> string option
end

type tool_ui_part

(** Tool invocation part with input, output, and state. *)
module Tool_part : sig
  type t = tool_ui_part

  val tool_call_id : t -> string
  val state : t -> string
  val tool_name : t -> string option
  val title : t -> string option
  val input : t -> Js.Json.t option
  val output : t -> Js.Json.t option
  val error_text : t -> string option
  val provider_executed : t -> bool option
end

type tool_approval

val tool_ui_part_approval : tool_ui_part -> tool_approval option
val tool_approval_id : tool_approval -> string

type source_url_ui_part

(** Source URL citation part. *)
module Source_url_part : sig
  type t = source_url_ui_part

  val source_id : t -> string
  val url : t -> string
  val title : t -> string option
end

type source_document_ui_part

(** Source document citation part. *)
module Source_document_part : sig
  type t = source_document_ui_part

  val source_id : t -> string
  val media_type : t -> string
  val title : t -> string
  val filename : t -> string option
end

type file_ui_part

(** File attachment part. *)
module File_part : sig
  type t = file_ui_part

  val media_type : t -> string
  val url : t -> string
  val filename : t -> string option
end

type step_start_ui_part

type data_ui_part

val data_ui_part_data : data_ui_part -> Js.Json.t
val data_ui_part_id : data_ui_part -> string option

(** The data type name without the ["data-"] prefix.
    E.g. for a part with type ["data-weather"], returns ["weather"]. *)
val data_ui_part_data_type : data_ui_part -> string

type ui_message_part

val part_type : ui_message_part -> string
val as_text : ui_message_part -> text_ui_part
val as_reasoning : ui_message_part -> reasoning_ui_part
val as_tool_call : ui_message_part -> tool_ui_part
val as_source_url : ui_message_part -> source_url_ui_part
val as_source_document : ui_message_part -> source_document_ui_part
val as_file : ui_message_part -> file_ui_part
val as_step_start : ui_message_part -> step_start_ui_part
val as_data : ui_message_part -> data_ui_part

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

(** Classify a message part into a typed variant.
    Matches ["dynamic-tool"] and ["tool-*"] as [Tool_call],
    ["data-*"] as [Data]. *)
val classify : ui_message_part -> classified_part

(** {1 UI Message} *)

type ui_message

(** UI message accessors. *)
module Message : sig
  type t = ui_message

  val id : t -> string
  val role : t -> role
  val role_raw : t -> string
  val parts : t -> ui_message_part array
  val metadata : t -> Js.Json.t option
end

(** @deprecated Use {!Message.id} *)
val ui_message_id : ui_message -> string

(** @deprecated Use {!Message.role} *)
val ui_message_role : ui_message -> role

(** @deprecated Use {!Message.role_raw} *)
val ui_message_role_raw : ui_message -> string

(** @deprecated Use {!Message.parts} *)
val ui_message_parts : ui_message -> ui_message_part array

(** @deprecated Use {!Message.metadata} *)
val ui_message_metadata : ui_message -> Js.Json.t option

(** @deprecated Use {!Text_part} module *)
val text_ui_part_text : text_ui_part -> string

(** @deprecated Use {!Text_part} module *)
val text_ui_part_state : text_ui_part -> string option

(** @deprecated Use {!Reasoning_part} module *)
val reasoning_ui_part_text : reasoning_ui_part -> string

(** @deprecated Use {!Reasoning_part} module *)
val reasoning_ui_part_state : reasoning_ui_part -> string option

(** @deprecated Use {!Tool_part} module *)
val tool_ui_part_tool_call_id : tool_ui_part -> string

(** @deprecated Use {!Tool_part} module *)
val tool_ui_part_state : tool_ui_part -> string

(** @deprecated Use {!Tool_part} module *)
val tool_ui_part_tool_name : tool_ui_part -> string option

(** @deprecated Use {!Tool_part} module *)
val tool_ui_part_title : tool_ui_part -> string option

(** @deprecated Use {!Tool_part} module *)
val tool_ui_part_input : tool_ui_part -> Js.Json.t option

(** @deprecated Use {!Tool_part} module *)
val tool_ui_part_output : tool_ui_part -> Js.Json.t option

(** @deprecated Use {!Tool_part} module *)
val tool_ui_part_error_text : tool_ui_part -> string option

(** @deprecated Use {!Tool_part} module *)
val tool_ui_part_provider_executed : tool_ui_part -> bool option

(** @deprecated Use {!Source_url_part} module *)
val source_url_ui_part_source_id : source_url_ui_part -> string

(** @deprecated Use {!Source_url_part} module *)
val source_url_ui_part_url : source_url_ui_part -> string

(** @deprecated Use {!Source_url_part} module *)
val source_url_ui_part_title : source_url_ui_part -> string option

(** @deprecated Use {!Source_document_part} module *)
val source_document_ui_part_source_id : source_document_ui_part -> string

(** @deprecated Use {!Source_document_part} module *)
val source_document_ui_part_media_type : source_document_ui_part -> string

(** @deprecated Use {!Source_document_part} module *)
val source_document_ui_part_title : source_document_ui_part -> string

(** @deprecated Use {!Source_document_part} module *)
val source_document_ui_part_filename : source_document_ui_part -> string option

(** @deprecated Use {!File_part} module *)
val file_ui_part_media_type : file_ui_part -> string

(** @deprecated Use {!File_part} module *)
val file_ui_part_url : file_ui_part -> string

(** @deprecated Use {!File_part} module *)
val file_ui_part_filename : file_ui_part -> string option

(** {1 Chat Request Options} *)

type chat_request_options

val make_chat_request_options :
  ?headers:string Js.Dict.t -> ?body:Js.Json.t -> ?metadata:Js.Json.t -> unit -> chat_request_options

(** {1 Error} *)

type error = Js.Exn.t
