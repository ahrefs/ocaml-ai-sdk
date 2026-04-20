(** Structured output smoke test — hits the live Anthropic Messages API.

    Exercises both paths of the Anthropic structured-output wiring:
    - Native [output_config.format = json_schema] on Sonnet 4.6
    - Synthetic [json] tool fallback on Sonnet 4.0 (no native support)

    The schema is derived from an OCaml type via [ppx_deriving_jsonschema], and the
    provider response is decoded back into the same OCaml type via [melange-json-native]'s
    [of_json] deriver. This exercises the full type-safe round-trip: schema → wire →
    parsed record.

    Usage:
      ANTHROPIC_API_KEY=$(passage get anthropic/staging/api_key) \
        dune exec examples/structured_output.exe

    Exit code: 0 if both paths decode into a valid [person] record, 1 otherwise. *)

open Melange_json.Primitives

(** Convert a ppx_deriving_jsonschema schema (Yojson.Safe.t) to Yojson.Basic.t for use
    with [Ai_core.Output.object_] / [Core_tool.parameters]. *)
let json_of_schema schema = Yojson.Safe.to_basic (Ppx_deriving_jsonschema_runtime.json_schema schema)

type person = {
  name : string;
  age : int;
  hobbies : string list;
}
[@@deriving jsonschema, of_json]

let prompt_text =
  "Invent a fictional person and respond with their name, age, and a short list of hobbies. Keep the hobbies list to \
   2-3 items."

let run_case ~label ~model_id =
  Printf.printf "\n=== %s (model: %s) ===\n" label model_id;
  let claude = Ai_provider_anthropic.model model_id in
  let output = Ai_core.Output.object_ ~name:"person" ~schema:(json_of_schema person_jsonschema) () in
  let opts =
    {
      (Ai_provider.Call_options.default
         ~prompt:
           [
             Ai_provider.Prompt.User
               { content = [ Text { text = prompt_text; provider_options = Ai_provider.Provider_options.empty } ] };
           ])
      with
      mode = Ai_core.Output.mode_of_output (Some output);
    }
  in
  let%lwt result = Ai_provider.Language_model.generate claude opts in
  Printf.printf "Finish reason: %s\n" (Ai_provider.Finish_reason.to_string result.finish_reason);
  Printf.printf "Tokens: %d in / %d out\n" result.usage.input_tokens result.usage.output_tokens;
  (* Reconstruct a Generate_text_result.step from the provider response so we can run it
     through Output.parse_output — the same path [generate_text] takes internally. *)
  let step : Ai_core.Generate_text_result.step =
    {
      text =
        List.fold_left
          (fun acc part ->
            match (part : Ai_provider.Content.t) with
            | Text { text } -> acc ^ text
            | _ -> acc)
          "" result.content;
      reasoning = "";
      tool_calls =
        List.filter_map
          (fun (part : Ai_provider.Content.t) ->
            match part with
            | Tool_call { tool_call_id; tool_name; args; _ } ->
              (match Yojson.Basic.from_string args with
              | json -> Some { Ai_core.Generate_text_result.tool_call_id; tool_name; args = json }
              | exception _ -> None)
            | _ -> None)
          result.content;
      tool_results = [];
      finish_reason = result.finish_reason;
      usage = result.usage;
    }
  in
  match Ai_core.Output.parse_output (Some output) [ step ] with
  | None ->
    Printf.printf "FAIL: parse_output returned None\n";
    Printf.printf "  step.text = %S\n" step.text;
    Printf.printf "  step.tool_calls = [%s]\n"
      (String.concat "; "
         (List.map
            (fun (tc : Ai_core.Generate_text_result.tool_call) ->
              Printf.sprintf "%s(%s)" tc.tool_name (Yojson.Basic.to_string tc.args))
            step.tool_calls));
    Lwt.return_false
  | Some json ->
  (* Decode the validated JSON into the [person] record via the of_json deriver. *)
  match person_of_json json with
  | p ->
    Printf.printf "Parsed person: name=%s age=%d hobbies=[%s]\n" p.name p.age (String.concat ", " p.hobbies);
    Lwt.return_true
  | exception exn ->
    Printf.printf "FAIL: of_json decoding failed: %s\n" (Printexc.to_string exn);
    Printf.printf "  JSON: %s\n" (Yojson.Basic.to_string json);
    Lwt.return_false

let () =
  let ok =
    Lwt_main.run
      begin
        let%lwt native_ok = run_case ~label:"Native structured outputs" ~model_id:"claude-sonnet-4-6" in
        let%lwt fallback_ok = run_case ~label:"Tool-use fallback" ~model_id:"claude-sonnet-4-0" in
        Lwt.return (native_ok && fallback_ok)
      end
  in
  match ok with
  | true ->
    Printf.printf "\nAll paths OK\n";
    exit 0
  | false ->
    Printf.printf "\nFailure\n";
    exit 1
