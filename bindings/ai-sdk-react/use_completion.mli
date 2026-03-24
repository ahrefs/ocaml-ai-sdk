open Types

(** The return value of the [useCompletion] hook. *)
type t

(** {1 Reading state} *)

val completion : t -> string
val input : t -> string
val is_loading : t -> bool
val error : t -> Js.Exn.t option

(** {1 Actions} *)

val complete : t -> string -> unit
val complete_with_options : t -> string -> chat_request_options -> unit
val stop : t -> unit
val set_completion : t -> string -> unit
val set_input : t -> string -> unit
val handle_input_change : t -> Dom.event -> unit
val handle_submit : t -> unit
val handle_submit_with_event : t -> Dom.event -> unit

(** {1 Hook}

    {[
      let h = Use_completion.use_completion ~api:"/api/completion" () in
      Use_completion.complete h "Write a poem"
    ]} *)

val use_completion :
  ?api:string ->
  ?id:string ->
  ?initial_input:string ->
  ?initial_completion:string ->
  ?credentials:string ->
  ?headers:string Js.Dict.t ->
  ?body:Js.Json.t ->
  ?stream_protocol:string ->
  ?on_finish:(string -> string -> unit) ->
  ?on_error:(Js.Exn.t -> unit) ->
  ?experimental_throttle:int ->
  unit ->
  t
