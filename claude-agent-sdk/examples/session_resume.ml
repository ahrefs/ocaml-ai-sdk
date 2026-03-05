open Claude_agent_sdk

let () =
  Lwt_main.run
    begin
      (* Session 1: tell Claude a fact *)
    let session_id = ref None in
    let%lwt messages =
      Query.run ~prompt:"My favorite color is blue. Remember this!"
        ~options:{ Options.default with model = Some "sonnet" }
        ()
    in
    let%lwt () =
      Lwt_stream.iter_s
        (fun msg ->
          (match msg with
          | Message.System s -> session_id := s.session_id
          | Message.Assistant a ->
            List.iter
              (function
                | Types.Text { text } -> Printf.printf "[Session 1] Claude: %s\n" text
                | _ -> ())
              a.message.content
          | _ -> ());
          Lwt.return_unit)
        messages
    in
    Printf.printf "--- Session closed. ---\n";

    (* Session 2: resume and verify Claude remembers *)
    let sid = Option.get !session_id in
    let%lwt messages =
      Query.run ~prompt:"What is my favorite color?"
        ~options:{ Options.default with model = Some "sonnet"; resume = Some sid }
        ()
    in
    Lwt_stream.iter_s
      (fun msg ->
        (match msg with
        | Message.Assistant a ->
          List.iter
            (function
              | Types.Text { text } -> Printf.printf "[Session 2] Claude: %s\n" text
              | _ -> ())
            a.message.content
        | _ -> ());
        Lwt.return_unit)
      messages
    end
