(* A mock provider that implements Language_model.S to prove
   the abstraction layer works end-to-end. *)

module Mock_model : Ai_provider.Language_model.S = struct
  let specification_version = "V3"
  let provider = "mock"
  let model_id = "mock-v1"

  let generate _opts =
    Lwt.return
      {
        Ai_provider.Generate_result.content = [ Ai_provider.Content.Text { text = "hello from mock" } ];
        finish_reason = Ai_provider.Finish_reason.Stop;
        usage = { Ai_provider.Usage.input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
        warnings = [];
        provider_metadata = Ai_provider.Provider_options.empty;
        request = { body = `Null };
        response = { id = Some "mock-r1"; model = Some "mock-v1"; headers = []; body = `Null };
      }

  let stream _opts =
    let stream, push = Lwt_stream.create () in
    push (Some (Ai_provider.Stream_part.Text { text = "hello " }));
    push (Some (Ai_provider.Stream_part.Text { text = "from mock" }));
    push
      (Some
         (Ai_provider.Stream_part.Finish
            {
              finish_reason = Ai_provider.Finish_reason.Stop;
              usage = { Ai_provider.Usage.input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
            }));
    push None;
    Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
end

(* Mock provider factory *)
module Mock_provider : Ai_provider.Provider.S = struct
  let name = "mock"

  let language_model model_id =
    (* Ignore model_id, always return Mock_model *)
    ignore (model_id : string);
    (module Mock_model : Ai_provider.Language_model.S)
end

(* Tests using the first-class module wrappers *)

let make_opts () =
  Ai_provider.Call_options.default
    ~prompt:
      [
        Ai_provider.Prompt.User
          { content = [ Text { text = "Hello"; provider_options = Ai_provider.Provider_options.empty } ] };
      ]

let test_generate_through_abstraction () =
  let model : Ai_provider.Language_model.t = (module Mock_model) in
  let opts = make_opts () in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (match result.content with
  | [ Ai_provider.Content.Text { text } ] -> Alcotest.(check string) "response text" "hello from mock" text
  | _ -> Alcotest.fail "expected single text content");
  Alcotest.(check string) "finish reason" "stop" (Ai_provider.Finish_reason.to_string result.finish_reason);
  Alcotest.(check int) "input tokens" 10 result.usage.input_tokens;
  Alcotest.(check int) "output tokens" 5 result.usage.output_tokens

let test_stream_through_abstraction () =
  let model : Ai_provider.Language_model.t = (module Mock_model) in
  let opts = make_opts () in
  let result = Lwt_main.run (Ai_provider.Language_model.stream model opts) in
  let parts = Lwt_main.run (Lwt_stream.to_list result.stream) in
  Alcotest.(check int) "3 parts" 3 (List.length parts);
  (* Check first part is text *)
  (match List.nth parts 0 with
  | Ai_provider.Stream_part.Text { text } -> Alcotest.(check string) "first text" "hello " text
  | _ -> Alcotest.fail "expected Text part");
  (* Check last part is Finish *)
  match List.nth parts 2 with
  | Ai_provider.Stream_part.Finish { finish_reason; _ } ->
    Alcotest.(check string) "finish" "stop" (Ai_provider.Finish_reason.to_string finish_reason)
  | _ -> Alcotest.fail "expected Finish part"

let test_provider_factory () =
  let provider : Ai_provider.Provider.t = (module Mock_provider) in
  Alcotest.(check string) "provider name" "mock" (Ai_provider.Provider.name provider);
  let model = Ai_provider.Provider.language_model provider "any-model" in
  Alcotest.(check string) "model id" "mock-v1" (Ai_provider.Language_model.model_id model);
  Alcotest.(check string) "model provider" "mock" (Ai_provider.Language_model.provider model)

let test_model_accessors () =
  let model : Ai_provider.Language_model.t = (module Mock_model) in
  Alcotest.(check string) "spec version" "V3" (Ai_provider.Language_model.specification_version model);
  Alcotest.(check string) "provider" "mock" (Ai_provider.Language_model.provider model);
  Alcotest.(check string) "model_id" "mock-v1" (Ai_provider.Language_model.model_id model)

let test_middleware () =
  let call_count = ref 0 in
  let middleware =
    (module struct
      let wrap_generate ~generate opts =
        incr call_count;
        generate opts

      let wrap_stream ~stream opts =
        incr call_count;
        stream opts
    end : Ai_provider.Middleware.S)
  in
  let model : Ai_provider.Language_model.t = (module Mock_model) in
  let wrapped = Ai_provider.Middleware.apply middleware model in
  let opts = make_opts () in
  let _result = Lwt_main.run (Ai_provider.Language_model.generate wrapped opts) in
  Alcotest.(check int) "middleware called" 1 !call_count;
  (* Verify the wrapped model preserves identity *)
  Alcotest.(check string) "wrapped model_id" "mock-v1" (Ai_provider.Language_model.model_id wrapped)

let () =
  Alcotest.run "Integration"
    [
      ( "language_model",
        [
          Alcotest.test_case "generate" `Quick test_generate_through_abstraction;
          Alcotest.test_case "stream" `Quick test_stream_through_abstraction;
          Alcotest.test_case "accessors" `Quick test_model_accessors;
        ] );
      "provider", [ Alcotest.test_case "factory" `Quick test_provider_factory ];
      "middleware", [ Alcotest.test_case "apply" `Quick test_middleware ];
    ]
