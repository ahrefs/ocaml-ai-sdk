(** A language model for tests, modelled on upstream's [MockLanguageModelV3].

    You choose what [generate] and [stream] return, and the mock records the
    {!Ai_provider.Call_options.t} of every call it receives, in order. A
    direction you don't set fails each call with [Failure].

    {[
      let model, mock =
        Ai_mock.Language_model.(create ~generate:(Return (generate_result [ Text { text = "Hi" } ])) ())
      in
      let%lwt result = Ai_core.Generate_text.generate_text ~model ~prompt:"Hello" () in
      (* [result.text] is "Hi", and [generate_calls mock] holds the options of
         the one call, including the prompt. *)
      Lwt.return (result.text, Ai_mock.Language_model.generate_calls mock)
    ]} *)

(** What a call returns. ['result] is the model's return type. ['canned] is a
    ready response: the result itself for [generate], the list of parts for
    [stream]. *)
type ('canned, 'result) response =
  | Return of 'canned  (** Every call gets this. *)
  | Sequence of 'canned list
    (** Call [n] gets the [n]th element, counting from 1, as in a multi-step
          tool loop. A call past the end fails with [Failure]. *)
  | Respond of (Ai_provider.Call_options.t -> 'result Lwt.t)  (** Each call gets [f options]. *)

type generate = (Ai_provider.Generate_result.t, Ai_provider.Generate_result.t) response

(** A canned stream is its list of parts. Each call gets a fresh stream of
    them, which then ends. *)
type stream = (Ai_provider.Stream_part.t list, Ai_provider.Stream_result.t) response

(** Records the calls made to one mock model. *)
type t

(** [create ?provider ?model_id ?generate ?stream ()] returns the model and its
    call record. [provider] defaults to ["mock-provider"] and [model_id] to
    ["mock-model-id"], as upstream. The mock records a call before computing
    its response. *)
val create :
  ?provider:string ->
  ?model_id:string ->
  ?generate:generate ->
  ?stream:stream ->
  unit ->
  Ai_provider.Language_model.t * t

(** The options of every [generate] call so far, oldest first. *)
val generate_calls : t -> Ai_provider.Call_options.t list

(** The options of every [stream] call so far, oldest first. *)
val stream_calls : t -> Ai_provider.Call_options.t list

(** {1 Building responses} *)

(** A result with [content]. [finish_reason] defaults to [Stop], [usage] to
    zero tokens, and every other field is empty. *)
val generate_result :
  ?finish_reason:Ai_provider.Finish_reason.t ->
  ?usage:Ai_provider.Usage.t ->
  Ai_provider.Content.t list ->
  Ai_provider.Generate_result.t

(** A stream result that sends [parts], then ends. *)
val stream_result : Ai_provider.Stream_part.t list -> Ai_provider.Stream_result.t

(** [Respond (hang ())] never returns. Unless [ignore_abort] is true, the call
    fails with [Ai_provider.Abort_signal.Aborted] once the abort signal in its
    options settles. The promise can be cancelled either way. *)
val hang : ?ignore_abort:bool -> unit -> Ai_provider.Call_options.t -> 'a Lwt.t

(** [Respond (hanging_stream parts)] returns a stream that sends [parts], then
    neither ends nor fails. Unless [ignore_abort] is true, the stream ends,
    with no [Finish] part, once the abort signal in the call's options settles,
    as a provider's stream does. *)
val hanging_stream :
  ?ignore_abort:bool ->
  Ai_provider.Stream_part.t list ->
  Ai_provider.Call_options.t ->
  Ai_provider.Stream_result.t Lwt.t
