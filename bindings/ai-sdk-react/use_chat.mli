open Types

(** The return value of the [useChat] hook. *)
type t

(** {1 Reading state} *)

val id : t -> string
val messages : t -> ui_message array
val status : t -> chat_status
val error : t -> Js.Exn.t option

(** {1 Setting messages} *)

val set_messages : t -> ui_message array -> unit
val set_messages_fn : t -> (ui_message array -> ui_message array) -> unit

(** {1 Sending messages} *)

type text_message

val make_text_message : text:string -> text_message

type text_message_with_metadata

val make_text_message_with_metadata : text:string -> ?metadata:Js.Json.t -> unit -> text_message_with_metadata
val send_message : t -> text_message -> unit
val send_message_with_metadata : t -> text_message_with_metadata -> unit
val send_text : t -> string -> unit
val send_message_with_options : t -> text_message -> chat_request_options -> unit

(** {1 Actions} *)

val regenerate : t -> unit
val stop : t -> unit
val resume_stream : t -> unit
val clear_error : t -> unit

(** {1 Tool interaction} *)

type tool_output

val make_tool_output : tool:string -> toolCallId:string -> output:Js.Json.t -> tool_output
val add_tool_output : t -> tool_output -> unit

type tool_approval_response

val make_tool_approval_response : id:string -> approved:bool -> ?reason:string -> unit -> tool_approval_response
val add_tool_approval_response : t -> tool_approval_response -> unit

(** {1 Auto-submit helpers} *)

type send_automatically_options

val send_automatically_options_messages : send_automatically_options -> ui_message array

(** Checks if all tool parts in the last assistant message have approval responses.
    Use with [~send_automatically_when] to auto-resubmit after tool approval. *)
val last_assistant_message_is_complete_with_approval_responses : send_automatically_options -> bool

(** Checks if all tool parts in the last assistant message have output.
    Use with [~send_automatically_when] to auto-resubmit after client tool output. *)
val last_assistant_message_is_complete_with_tool_calls : send_automatically_options -> bool

(** {1 Transport} *)

type transport

module Default_chat_transport : sig
  type t

  val make : ?api:string -> ?credentials:string -> ?headers:string Js.Dict.t -> ?body:Js.Json.t -> unit -> t
  val to_transport : t -> transport
end

(** {1 Hook}

    {[
      let chat =
        Use_chat.use_chat
          ~transport:(Use_chat.Default_chat_transport.(make ~api:"/api/chat" () |> to_transport))
          ()
      in
      Use_chat.send_text chat "Hello!"
    ]} *)

val use_chat :
  ?id:string ->
  ?messages:ui_message array ->
  ?transport:transport ->
  ?on_error:(Js.Exn.t -> unit) ->
  ?on_tool_call:(Js.Json.t -> unit Js.Promise.t) ->
  ?on_finish:(Js.Json.t -> unit) ->
  ?on_data:(Js.Json.t -> unit) ->
  ?send_automatically_when:(send_automatically_options -> bool) ->
  ?experimental_throttle:int ->
  ?resume:bool ->
  unit ->
  t
