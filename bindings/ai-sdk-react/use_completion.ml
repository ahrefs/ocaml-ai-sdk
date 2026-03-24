open Types

(** {1 Return type} *)

type t

external completion : t -> string = "completion" [@@mel.get]
external input : t -> string = "input" [@@mel.get]
external is_loading : t -> bool = "isLoading" [@@mel.get]
external error : t -> Js.Exn.t option = "error" [@@mel.get] [@@mel.return nullable]

external complete : t -> string -> unit = "complete" [@@mel.send]

external complete_with_options : t -> string -> chat_request_options -> unit = "complete" [@@mel.send]

external stop : t -> unit = "stop" [@@mel.send]
external set_completion : t -> string -> unit = "setCompletion" [@@mel.send]
external set_input : t -> string -> unit = "setInput" [@@mel.send]
external handle_input_change : t -> Dom.event -> unit = "handleInputChange" [@@mel.send]
external handle_submit : t -> unit = "handleSubmit" [@@mel.send]

external handle_submit_with_event : t -> Dom.event -> unit = "handleSubmit" [@@mel.send]

(** {1 Options & Hook} *)

type options

external make_options :
  ?api:string ->
  ?id:string ->
  ?initialInput:string ->
  ?initialCompletion:string ->
  ?credentials:string ->
  ?headers:string Js.Dict.t ->
  ?body:Js.Json.t ->
  ?streamProtocol:string ->
  ?onFinish:(string -> string -> unit) ->
  ?onError:(Js.Exn.t -> unit) ->
  ?experimental_throttle:int ->
  unit ->
  options = ""
[@@mel.obj]

external use_completion_raw : options option -> t = "useCompletion" [@@mel.module "@ai-sdk/react"]

let use_completion ?api ?id ?initial_input ?initial_completion ?credentials ?headers ?body ?stream_protocol ?on_finish
  ?on_error ?experimental_throttle () =
  let opts =
    make_options ?api ?id ?initialInput:initial_input ?initialCompletion:initial_completion ?credentials ?headers ?body
      ?streamProtocol:stream_protocol ?onFinish:on_finish ?onError:on_error ?experimental_throttle ()
  in
  use_completion_raw (Some opts)
