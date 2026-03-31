open Types

(** {1 Return type} *)

type t

external id : t -> string = "id" [@@mel.get]
external messages : t -> ui_message array = "messages" [@@mel.get]
external status_raw : t -> string = "status" [@@mel.get]
external error : t -> Js.Exn.t option = "error" [@@mel.get] [@@mel.return nullable]

let status (h : t) : chat_status =
  match status_raw h with
  | "submitted" -> Submitted
  | "streaming" -> Streaming
  | "ready" -> Ready
  | "error" -> Error
  | _ -> Ready

external set_messages : t -> ui_message array -> unit = "setMessages" [@@mel.send]

external set_messages_fn : t -> (ui_message array -> ui_message array) -> unit = "setMessages" [@@mel.send]

(** {1 Sending messages} *)

type text_message

external make_text_message : text:string -> text_message = "" [@@mel.obj]

type text_message_with_metadata

external make_text_message_with_metadata : text:string -> ?metadata:Js.Json.t -> unit -> text_message_with_metadata = ""
[@@mel.obj]

external send_message : t -> text_message -> unit = "sendMessage" [@@mel.send]

external send_message_with_metadata : t -> text_message_with_metadata -> unit = "sendMessage" [@@mel.send]

let send_text (h : t) (text : string) = send_message h (make_text_message ~text)

external send_message_with_options : t -> text_message -> chat_request_options -> unit = "sendMessage" [@@mel.send]

(** {1 Actions} *)

external regenerate : t -> unit = "regenerate" [@@mel.send]
external stop : t -> unit = "stop" [@@mel.send]
external resume_stream : t -> unit = "resumeStream" [@@mel.send]
external clear_error : t -> unit = "clearError" [@@mel.send]

(** {1 Tool interaction} *)

type tool_output

external make_tool_output : tool:string -> toolCallId:string -> output:Js.Json.t -> tool_output = "" [@@mel.obj]

external add_tool_output : t -> tool_output -> unit = "addToolOutput" [@@mel.send]

type tool_approval_response

external make_tool_approval_response : id:string -> approved:bool -> ?reason:string -> unit -> tool_approval_response
  = ""
[@@mel.obj]

external add_tool_approval_response : t -> tool_approval_response -> unit = "addToolApprovalResponse" [@@mel.send]

(** {1 Transport} *)

type transport

module Default_chat_transport = struct
  type t
  type init

  external make_init :
    ?api:string -> ?credentials:string -> ?headers:string Js.Dict.t -> ?body:Js.Json.t -> unit -> init = ""
  [@@mel.obj]

  external create : init -> t = "DefaultChatTransport" [@@mel.new] [@@mel.module "ai"]

  let make ?api ?credentials ?headers ?body () = create (make_init ?api ?credentials ?headers ?body ())

  external to_transport : t -> transport = "%identity"
end

(** {1 Auto-submit helpers} *)

type send_automatically_options

external send_automatically_options_messages : send_automatically_options -> ui_message array = "messages" [@@mel.get]

(** Checks if all tool parts in the last assistant message have approval responses.
    Use with [~send_automatically_when] to auto-resubmit after tool approval. *)
external last_assistant_message_is_complete_with_approval_responses : send_automatically_options -> bool
  = "lastAssistantMessageIsCompleteWithApprovalResponses"
[@@mel.module "ai"]

(** {1 Options & Hook} *)

type options

external make_options :
  ?id:string ->
  ?messages:ui_message array ->
  ?transport:transport ->
  ?onError:(Js.Exn.t -> unit) ->
  ?onToolCall:(Js.Json.t -> unit) ->
  ?onFinish:(Js.Json.t -> unit) ->
  ?onData:(Js.Json.t -> unit) ->
  ?sendAutomaticallyWhen:(send_automatically_options -> bool) ->
  ?experimental_throttle:int ->
  ?resume:bool ->
  unit ->
  options = ""
[@@mel.obj]

external use_chat_raw : options option -> t = "useChat" [@@mel.module "@ai-sdk/react"]

let use_chat ?id ?messages ?transport ?on_error ?on_tool_call ?on_finish ?on_data ?send_automatically_when
  ?experimental_throttle ?resume () =
  let opts =
    make_options ?id ?messages ?transport ?onError:on_error ?onToolCall:on_tool_call ?onFinish:on_finish ?onData:on_data
      ?sendAutomaticallyWhen:send_automatically_when ?experimental_throttle ?resume ()
  in
  use_chat_raw (Some opts)
