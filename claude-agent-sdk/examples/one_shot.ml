open Claude_agent_sdk

let () =
  Lwt_main.run
    begin
      let%lwt messages =
        Query.run ~prompt:"What is the capital of France? One word."
          ~options:{ Options.default with model = Some "sonnet" }
          ()
      in
      Lwt_stream.iter_s
        (fun msg ->
          (match msg with
          | Message.Result r when r.subtype = "success" ->
            Printf.printf "Answer: %s\n" (CCOption.value ~default:"" r.result);
            Printf.printf "Cost: $%.4f\n" (CCOption.value ~default:0. r.total_cost_usd)
          | Message.Assistant a ->
            List.iter
              (function
                | Types.Text { text } -> print_string text
                | _ -> ())
              a.message.content
          | _ -> ());
          Lwt.return_unit)
        messages
    end
