(** Tool use example.

    Demonstrates defining tools and handling tool call responses.
    Set ANTHROPIC_API_KEY environment variable before running.

    Usage: dune exec examples/tool_use.exe *)

let () =
  Lwt_main.run
    begin
      let claude = Ai_provider_anthropic.model "claude-sonnet-4-6" in

      (* Define a tool *)
      let weather_tool : Ai_provider.Tool.t =
        {
          name = "get_weather";
          description = Some "Get the current weather for a city";
          parameters =
            `Assoc
              [
                "type", `String "object";
                ( "properties",
                  `Assoc [ "city", `Assoc [ "type", `String "string"; "description", `String "The city name" ] ] );
                "required", `List [ `String "city" ];
              ];
        }
      in

      let opts =
        {
          (Ai_provider.Call_options.default
             ~prompt:
               [
                 Ai_provider.Prompt.User
                   {
                     content =
                       [
                         Text
                           {
                             text = "What's the weather like in Paris?";
                             provider_options = Ai_provider.Provider_options.empty;
                           };
                       ];
                   };
               ])
          with
          tools = [ weather_tool ];
          tool_choice = Some Auto;
        }
      in

      let%lwt result = Ai_provider.Language_model.generate claude opts in

      (* Handle the response — might contain text and/or tool calls *)
      List.iter
        (fun (part : Ai_provider.Content.t) ->
          match part with
          | Text { text } -> Printf.printf "Claude says: %s\n" text
          | Tool_call { tool_name; tool_call_id; args; _ } ->
            Printf.printf "Claude wants to call: %s (id: %s)\n" tool_name tool_call_id;
            Printf.printf "  Arguments: %s\n" args;
            Printf.printf "\nIn a real app, you would:\n";
            Printf.printf "  1. Execute the tool with these args\n";
            Printf.printf "  2. Send the result back as a Tool message\n";
            Printf.printf "  3. Call generate again to get the final response\n"
          | Reasoning { text; _ } -> Printf.printf "[Thinking: %s]\n" text
          | File _ -> Printf.printf "[File]\n"
          | Source { url; _ } -> Printf.printf "[Source: %s]\n" url)
        result.content;

      Printf.printf "\nFinish reason: %s\n" (Ai_provider.Finish_reason.to_string result.finish_reason);

      Lwt.return_unit
    end
