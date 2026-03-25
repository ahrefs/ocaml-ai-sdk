open Melange_json.Primitives
open Alcotest

type query_args = { query : string } [@@json.allow_extra_fields] [@@deriving of_json]

(* Mock streaming model -- emits text deltas *)
let make_text_stream_model response_text =
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-stream"

    let generate _opts =
      Lwt.return
        {
          Ai_provider.Generate_result.content = [ Ai_provider.Content.Text { text = response_text } ];
          finish_reason = Stop;
          usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
          warnings = [];
          provider_metadata = Ai_provider.Provider_options.empty;
          request = { body = `Null };
          response = { id = None; model = None; headers = []; body = `Null };
        }

    let stream _opts =
      let stream, push = Lwt_stream.create () in
      push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
      (* Split text into characters for realistic streaming *)
      String.iter (fun c -> push (Some (Ai_provider.Stream_part.Text { text = String.make 1 c }))) response_text;
      push
        (Some
           (Ai_provider.Stream_part.Finish
              { finish_reason = Stop; usage = { input_tokens = 10; output_tokens = 5; total_tokens = Some 15 } }));
      push None;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

(* Mock model that streams a tool call then text on second call *)
let make_tool_stream_model () =
  let call_count = ref 0 in
  let module M : Ai_provider.Language_model.S = struct
    let specification_version = "V3"
    let provider = "mock"
    let model_id = "mock-tool-stream"

    let generate _opts = Lwt.fail_with "not implemented"

    let stream _opts =
      incr call_count;
      let stream, push = Lwt_stream.create () in
      if !call_count = 1 then begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "Searching..." }));
        push
          (Some
             (Ai_provider.Stream_part.Tool_call_delta
                {
                  tool_call_type = "function";
                  tool_call_id = "tc_1";
                  tool_name = "search";
                  args_text_delta = {|{"query":"test"}|};
                }));
        push (Some (Ai_provider.Stream_part.Tool_call_finish { tool_call_id = "tc_1" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                { finish_reason = Tool_calls; usage = { input_tokens = 10; output_tokens = 8; total_tokens = Some 18 } }));
        push None
      end
      else begin
        push (Some (Ai_provider.Stream_part.Stream_start { warnings = [] }));
        push (Some (Ai_provider.Stream_part.Text { text = "Found it!" }));
        push
          (Some
             (Ai_provider.Stream_part.Finish
                { finish_reason = Stop; usage = { input_tokens = 20; output_tokens = 5; total_tokens = Some 25 } }));
        push None
      end;
      Lwt.return { Ai_provider.Stream_result.stream; warnings = []; raw_response = None }
  end in
  (module M : Ai_provider.Language_model.S)

let search_tool : Ai_core.Core_tool.t =
  {
    description = Some "Search";
    parameters = `Assoc [ "type", `String "object" ];
    execute =
      (fun args ->
        let q = try (query_args_of_json args).query with _ -> "?" in
        Lwt.return (`String (Printf.sprintf "Results for: %s" q)));
  }

(* Tests *)

let test_simple_stream () =
  let model = make_text_stream_model "Hello" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Say hello" () in
  (* Collect text *)
  let texts = Lwt_main.run (Lwt_stream.to_list result.text_stream) in
  let full_text = String.concat "" texts in
  (check string) "text" "Hello" full_text;
  (* Check usage resolves *)
  let usage = Lwt_main.run result.usage in
  (check int) "input" 10 usage.input_tokens

let test_full_stream_events () =
  let model = make_text_stream_model "Hi" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" () in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Should have: Start, Start_step, Text_start, Text_delta(s), Text_end, Finish_step, Finish *)
  let has_start =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Start -> true
        | _ -> false)
      parts
  in
  let has_finish =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Finish _ -> true
        | _ -> false)
      parts
  in
  (check bool) "has Start" true has_start;
  (check bool) "has Finish" true has_finish

let test_tool_stream_loop () =
  let model = make_tool_stream_model () in
  let result =
    Ai_core.Stream_text.stream_text ~model ~prompt:"Search" ~tools:[ "search", search_tool ] ~max_steps:3 ()
  in
  let parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Should include tool call, tool result, and final text *)
  let has_tool_call =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_call _ -> true
        | _ -> false)
      parts
  in
  let has_tool_result =
    List.exists
      (fun p ->
        match p with
        | Ai_core.Text_stream_part.Tool_result _ -> true
        | _ -> false)
      parts
  in
  (check bool) "has Tool_call" true has_tool_call;
  (check bool) "has Tool_result" true has_tool_result;
  (* Check steps *)
  let steps = Lwt_main.run result.steps in
  (check int) "2 steps" 2 (List.length steps);
  (* Check aggregated usage *)
  let usage = Lwt_main.run result.usage in
  (check int) "total input" 30 usage.input_tokens

let test_on_chunk_callback () =
  let chunk_count = ref 0 in
  let model = make_text_stream_model "Hi" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Hello" ~on_chunk:(fun _ -> incr chunk_count) () in
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (check bool) "chunks received" true (!chunk_count > 0)

let test_finish_reason () =
  let model = make_text_stream_model "Done" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Test" () in
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  let fr = Lwt_main.run result.finish_reason in
  (check string) "stop" "stop" (Ai_provider.Finish_reason.to_string fr)

let test_stream_with_object_output () =
  let json_text = {|{"name":"Alice","age":30}|} in
  let model = make_text_stream_model json_text in
  let schema =
    `Assoc
      [
        "type", `String "object";
        ( "properties",
          `Assoc [ "name", `Assoc [ "type", `String "string" ]; "age", `Assoc [ "type", `String "integer" ] ] );
        "required", `List [ `String "name"; `String "age" ];
        "additionalProperties", `Bool false;
      ]
  in
  let output = Ai_core.Output.object_ ~name:"person" ~schema () in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Give me a person" ~output () in
  (* Drain full_stream to let background task complete *)
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Check partial output stream has entries *)
  let partials = Lwt_main.run (Lwt_stream.to_list result.partial_output_stream) in
  (check bool) "has partial outputs" true (List.length partials > 0);
  (* Check final output resolves to parsed JSON *)
  let final_output = Lwt_main.run result.output in
  match final_output with
  | Some json -> (check string) "output json" json_text (Yojson.Basic.to_string json)
  | None -> fail "expected Some output"

let test_stream_without_output () =
  let model = make_text_stream_model "Hello world" in
  let result = Ai_core.Stream_text.stream_text ~model ~prompt:"Say hello" () in
  (* Drain full_stream to let background task complete *)
  let _parts = Lwt_main.run (Lwt_stream.to_list result.full_stream) in
  (* Check partial output stream is empty *)
  let partials = Lwt_main.run (Lwt_stream.to_list result.partial_output_stream) in
  (check int) "no partial outputs" 0 (List.length partials);
  (* Check output is None *)
  let final_output = Lwt_main.run result.output in
  (check bool) "output is None" true (Option.is_none final_output)

let () =
  run "Stream_text"
    [
      ( "basic",
        [
          test_case "simple" `Quick test_simple_stream;
          test_case "full_events" `Quick test_full_stream_events;
          test_case "finish_reason" `Quick test_finish_reason;
        ] );
      "tools", [ test_case "tool_loop" `Quick test_tool_stream_loop ];
      "callbacks", [ test_case "on_chunk" `Quick test_on_chunk_callback ];
      ( "output",
        [
          test_case "with_object_output" `Quick test_stream_with_object_output;
          test_case "without_output" `Quick test_stream_without_output;
        ] );
    ]
