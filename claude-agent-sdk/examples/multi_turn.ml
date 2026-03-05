open Claude_agent_sdk

let print_assistant_text msgs =
  List.iter
    (fun msg ->
      match msg with
      | Message.Assistant a ->
        List.iter
          (function
            | Types.Text { text } -> print_string text
            | _ -> ())
          a.message.content
      | _ -> ())
    msgs

let () =
  Lwt_main.run
    begin
      Client.with_client ~options:{ Options.default with model = Some "sonnet" }
        ~prompt:"What is 5 + 3? Just the number." (fun client ->
        (* Turn 1 *)
        let%lwt msgs = Client.receive_until_result client in
        Printf.printf "Turn 1: ";
        print_assistant_text msgs;
        print_newline ();

        (* Turn 2 — Claude remembers "8" from Turn 1 *)
        let%lwt () = Client.send_query client ~prompt:"Multiply that by 2. Just the number." in
        let%lwt msgs = Client.receive_until_result client in
        Printf.printf "Turn 2: ";
        print_assistant_text msgs;
        print_newline ();
        Lwt.return_unit)
    end
