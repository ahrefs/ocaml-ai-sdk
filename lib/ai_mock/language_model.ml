type ('canned, 'result) response =
  | Return of 'canned
  | Sequence of 'canned list
  | Respond of (Ai_provider.Call_options.t -> 'result Lwt.t)

type generate = (Ai_provider.Generate_result.t, Ai_provider.Generate_result.t) response
type stream = (Ai_provider.Stream_part.t list, Ai_provider.Stream_result.t) response

type t = {
  mutable generate_calls : Ai_provider.Call_options.t list;  (** Newest first. *)
  mutable stream_calls : Ai_provider.Call_options.t list;  (** Newest first. *)
}

let generate_calls t = List.rev t.generate_calls
let stream_calls t = List.rev t.stream_calls

let generate_result ?(finish_reason = Ai_provider.Finish_reason.Stop)
  ?(usage = { Ai_provider.Usage.input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }) content =
  {
    Ai_provider.Generate_result.content;
    finish_reason;
    usage;
    warnings = [];
    provider_metadata = Ai_provider.Provider_options.empty;
    request = { body = `Null };
    response = { id = None; model = None; headers = []; body = `Null };
  }

let stream_result parts =
  { Ai_provider.Stream_result.stream = Lwt_stream.of_list parts; warnings = []; raw_response = None }

(* A promise that never resolves, but that [Lwt.cancel] can still cancel. *)
let never () =
  let promise, (_ : _ Lwt.u) = Lwt.task () in
  promise

let abort_signal ~ignore_abort (options : Ai_provider.Call_options.t) =
  match ignore_abort with
  | true -> None
  | false -> options.abort_signal

let hang ?(ignore_abort = false) () options =
  match abort_signal ~ignore_abort options with
  | None -> never ()
  | Some signal ->
    Lwt.bind (Ai_provider.Abort_signal.wait signal) (fun () ->
      Lwt.fail (Ai_provider.Abort_signal.Aborted { reason = Ai_provider.Abort_signal.reason signal }))

let hanging_stream ?(ignore_abort = false) parts options =
  let stream, push = Lwt_stream.create () in
  List.iter (fun part -> push (Some part)) parts;
  Option.iter
    (fun signal -> Lwt.on_success (Ai_provider.Abort_signal.wait signal) (fun () -> push None))
    (abort_signal ~ignore_abort options);
  Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }

(* Answers call number [call] (from 1) with [response], building a canned
   value's result with [of_canned]. *)
let respond ~direction ~of_canned response ~call options =
  match response with
  | Return canned -> Lwt.return (of_canned canned)
  | Respond f -> f options
  | Sequence canned_list ->
  match List.nth_opt canned_list (call - 1) with
  | Some canned -> Lwt.return (of_canned canned)
  | None ->
    Lwt.fail
      (Failure
         (Printf.sprintf "Ai_mock.Language_model: %s call %d, but the sequence has %d responses" direction call
            (List.length canned_list)))

let not_implemented ~direction (_ : Ai_provider.Call_options.t) =
  Lwt.fail (Failure (Printf.sprintf "Ai_mock.Language_model: %s is not implemented" direction))

let create ?(provider = "mock-provider") ?(model_id = "mock-model-id") ?generate ?stream () =
  let t = { generate_calls = []; stream_calls = [] } in
  let generate_response =
    match generate with
    | Some response -> respond ~direction:"generate" ~of_canned:Fun.id response
    | None -> fun ~call:_ -> not_implemented ~direction:"generate"
  in
  let stream_response =
    match stream with
    | Some response -> respond ~direction:"stream" ~of_canned:stream_result response
    | None -> fun ~call:_ -> not_implemented ~direction:"stream"
  in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = provider
    let model_id = model_id

    let generate options =
      t.generate_calls <- options :: t.generate_calls;
      generate_response ~call:(List.length t.generate_calls) options

    let stream options =
      t.stream_calls <- options :: t.stream_calls;
      stream_response ~call:(List.length t.stream_calls) options
  end in
  (module M : Ai_provider.Language_model.S), t
