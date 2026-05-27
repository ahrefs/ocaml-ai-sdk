open Alcotest

module CP = Ai_provider_openrouter.Convert_prompt
module CC = Ai_provider_openrouter.Cache_control
module CCO = Ai_provider_openrouter.Cache_control_options
module PO = Ai_provider.Provider_options

let json_field key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let convert_one ~system_message_mode msg =
  let msgs, _ = CP.convert_messages ~system_message_mode [ msg ] in
  match msgs with
  | [ m ] -> CP.openrouter_message_to_json m
  | _ -> failwith "expected exactly one converted message"

(* --- System message tests (plan §4.2, §11: wire change to array form) --- *)

let test_system_no_cache_emits_array_form () =
  (* Plan §4.2: system message ALWAYS uses array-of-one-text-part form,
     even when no cache_control is set.
     Upstream switch case 'system' (convert-to-openrouter-chat-messages.ts ~62-77). *)
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.System { content = "You are helpful"; provider_options = PO.empty })
  in
  (match json_field "role" json with
  | Some (`String r) -> check string "role" "system" r
  | _ -> fail "role missing");
  match json_field "content" json with
  | Some (`List [ `Assoc fs ]) ->
    (match List.assoc_opt "type" fs with
    | Some (`String "text") -> ()
    | _ -> fail "expected type=text");
    (match List.assoc_opt "text" fs with
    | Some (`String "You are helpful") -> ()
    | _ -> fail "expected text body");
    check bool "no cache_control field" true (Option.is_none (List.assoc_opt "cache_control" fs))
  | _ -> fail "expected content as single-element array"

let test_system_with_cache_control () =
  let po = CCO.with_cache_control ~cache_control:CC.ephemeral PO.empty in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.System { content = "Cached system"; provider_options = po })
  in
  match json_field "content" json with
  | Some (`List [ `Assoc fs ]) ->
    (match List.assoc_opt "cache_control" fs with
    | Some (`Assoc cfs) ->
      (match List.assoc_opt "type" cfs with
      | Some (`String "ephemeral") -> ()
      | _ -> fail "cache_control.type")
    | _ -> fail "expected cache_control on text part")
  | _ -> fail "expected single-element content array"

let test_system_with_anthropic_fallback () =
  (* Plan: prompts written for Anthropic-native should work unchanged
     through OpenRouter via the Anthropic key fallback in
     get_cache_control. Mirrors upstream's
     anthropic.cacheControl ?? anthropic.cache_control fallback. *)
  let po =
    Ai_provider_anthropic.Cache_control_options.with_cache_control
      ~cache_control:Ai_provider_anthropic.Cache_control.ephemeral PO.empty
  in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.System { content = "via anthropic key"; provider_options = po })
  in
  match json_field "content" json with
  | Some (`List [ `Assoc fs ]) ->
    (match List.assoc_opt "cache_control" fs with
    | Some (`Assoc _) -> ()
    | _ -> fail "expected cache_control from anthropic-key fallback")
  | _ -> fail "expected single-element content array"

(* --- User single-text tests (plan §4.3) --- *)

let test_user_single_text_no_cache_emits_string () =
  (* Plan §4.3: no shape change when no cache_control. *)
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.User { content = [ Text { text = "Hello"; provider_options = PO.empty } ] })
  in
  (match json_field "role" json with
  | Some (`String "user") -> ()
  | _ -> fail "role");
  match json_field "content" json with
  | Some (`String "Hello") -> ()
  | _ -> fail "expected string content for no-cache single text"

let test_user_single_text_message_cache () =
  let mpo = CCO.with_cache_control ~cache_control:CC.ephemeral PO.empty in
  let msgs, _ =
    CP.convert_messages ~system_message_mode:System
      [
        Ai_provider.Prompt.System
          { content = "preamble"; provider_options = mpo }
        (* sneak the message_po onto the user via Prompt.User — Prompt.User has no
           provider_options field, so we instead test the equivalent path: a part-level
           cache_control. The single-text path's "message_po wins" branch is exercised
           below indirectly via the multi-part path's message_cc fallback. *);
      ]
  in
  (* This test is just verifying the system path with cache_control still works;
     for the user single-text message-level case we cannot construct it because
     [Prompt.User] currently has no provider_options field. *)
  match msgs with
  | [ _ ] -> ()
  | _ -> fail "expected single converted message"

let test_user_single_text_part_cache () =
  (* Plan §4.3: part-level cache_control on the one text part flips
     content from string to one-element array with cache_control inside. *)
  let ppo = CCO.with_cache_control ~cache_control:CC.ephemeral PO.empty in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.User
         { content = [ Text { text = "cached user"; provider_options = ppo } ] })
  in
  match json_field "content" json with
  | Some (`List [ `Assoc fs ]) ->
    (match List.assoc_opt "type" fs with
    | Some (`String "text") -> ()
    | _ -> fail "expected text part");
    (match List.assoc_opt "text" fs with
    | Some (`String "cached user") -> ()
    | _ -> fail "expected text body");
    (match List.assoc_opt "cache_control" fs with
    | Some (`Assoc _) -> ()
    | _ -> fail "expected cache_control on the one text part")
  | _ -> fail "expected one-element array content"

let test_user_single_text_public_serializer_with_cache () =
  let json =
    CP.openrouter_message_to_json
      (CP.User_msg_single_text { text = "public cached"; cache_control = Some CC.ephemeral })
  in
  match json_field "content" json with
  | Some (`List [ `Assoc fs ]) ->
    (match List.assoc_opt "type" fs with
    | Some (`String "text") -> ()
    | _ -> fail "expected text part");
    (match List.assoc_opt "text" fs with
    | Some (`String "public cached") -> ()
    | _ -> fail "expected text body");
    (match List.assoc_opt "cache_control" fs with
    | Some (`Assoc _) -> ()
    | _ -> fail "expected cache_control on public single-text serializer")
  | _ -> fail "expected one-element array content"

(* --- User multi-part tests (plan §4.4) --- *)

(* The Prompt.User variant currently has no [provider_options] field, so
   message-level cache_control on user messages cannot be expressed via the
   public Prompt API. We test the multi-part path's behavior using only
   per-part cache_control (which is upstream's main path anyway). *)

let test_user_multipart_part_cache_only () =
  (* Cache only on the SECOND text part; the first text part gets none. *)
  let ppo = CCO.with_cache_control ~cache_control:CC.ephemeral PO.empty in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.User
         {
           content =
             [
               Text { text = "first"; provider_options = PO.empty };
               Text { text = "second"; provider_options = ppo };
             ];
         })
  in
  match json_field "content" json with
  | Some (`List [ `Assoc fs0; `Assoc fs1 ]) ->
    check bool "first part no cache" true (Option.is_none (List.assoc_opt "cache_control" fs0));
    (match List.assoc_opt "cache_control" fs1 with
    | Some (`Assoc _) -> ()
    | _ -> fail "expected cache_control on second part")
  | _ -> fail "expected two-part content"

let test_user_multipart_image_with_cache () =
  let ppo = CCO.with_cache_control ~cache_control:CC.ephemeral PO.empty in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.User
         {
           content =
             [
               Text { text = "look"; provider_options = PO.empty };
               File
                 {
                   data = Url "https://example.com/x.png";
                   media_type = "image/png";
                   filename = None;
                   provider_options = ppo;
                 };
             ];
         })
  in
  match json_field "content" json with
  | Some (`List [ _; `Assoc image_fs ]) ->
    (match List.assoc_opt "type" image_fs with
    | Some (`String "image_url") -> ()
    | _ -> fail "image part type");
    (match List.assoc_opt "cache_control" image_fs with
    | Some (`Assoc _) -> ()
    | _ -> fail "expected cache_control on image part")
  | _ -> fail "expected two-part content"

let test_user_multipart_no_root_cache () =
  (* Plan §4.4: NO root-level cache_control on multi-part user messages. *)
  let ppo = CCO.with_cache_control ~cache_control:CC.ephemeral PO.empty in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.User
         {
           content =
             [
               Text { text = "a"; provider_options = ppo };
               Text { text = "b"; provider_options = PO.empty };
             ];
         })
  in
  match json with
  | `Assoc fs -> check bool "no root cache_control" true (Option.is_none (List.assoc_opt "cache_control" fs))
  | _ -> fail "expected assoc"

(* --- Assistant message tests (plan §4.5) --- *)

let test_assistant_no_cache_no_field () =
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.Assistant
         { content = [ Text { text = "hi"; provider_options = PO.empty } ] })
  in
  match json with
  | `Assoc fs ->
    check bool "no cache_control field" true (Option.is_none (List.assoc_opt "cache_control" fs));
    (match List.assoc_opt "content" fs with
    | Some (`String "hi") -> ()
    | _ -> fail "expected content string")
  | _ -> fail "assoc"

let test_assistant_with_tool_call_no_cache_no_field () =
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.Assistant
         {
           content =
             [
               Text { text = "calling"; provider_options = PO.empty };
               Tool_call
                 {
                   id = "call_1";
                   name = "do_thing";
                   args = `Assoc [ "x", `Int 1 ];
                   provider_options = PO.empty;
                 };
             ];
         })
  in
  match json with
  | `Assoc fs ->
    check bool "no cache_control field" true (Option.is_none (List.assoc_opt "cache_control" fs));
    (match List.assoc_opt "tool_calls" fs with
    | Some (`List [ _ ]) -> ()
    | _ -> fail "expected one tool_call")
  | _ -> fail "assoc"

let test_assistant_text_part_cache_hoisted () =
  let po = CCO.with_cache_control ~cache_control:CC.ephemeral PO.empty in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.Assistant
         { content = [ Text { text = "cached assistant"; provider_options = po } ] })
  in
  match json with
  | `Assoc fs ->
    (match List.assoc_opt "content" fs with
    | Some (`String "cached assistant") -> ()
    | _ -> fail "expected content string");
    (match List.assoc_opt "cache_control" fs with
    | Some (`Assoc cfs) ->
      (match List.assoc_opt "type" cfs with
      | Some (`String "ephemeral") -> ()
      | _ -> fail "cache_control.type")
    | _ -> fail "expected root cache_control from assistant text part")
  | _ -> fail "assoc"

let test_assistant_tool_call_part_cache_hoisted () =
  let po = CCO.with_cache_control ~cache_control:CC.ephemeral PO.empty in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.Assistant
         {
           content =
             [
               Tool_call
                 {
                   id = "call_cached";
                   name = "do_cached";
                   args = `Assoc [ "x", `Int 1 ];
                   provider_options = po;
                 };
             ];
         })
  in
  match json with
  | `Assoc fs ->
    (match List.assoc_opt "tool_calls" fs with
    | Some (`List [ _ ]) -> ()
    | _ -> fail "expected one tool_call");
    (match List.assoc_opt "cache_control" fs with
    | Some (`Assoc _) -> ()
    | _ -> fail "expected root cache_control from assistant tool_call part")
  | _ -> fail "assoc"

(* Note: the Prompt.Assistant variant currently has no [provider_options]
   field, so root-level cache_control on assistant messages cannot be
   exercised end-to-end via the public Prompt API today. Until that surface is
   added, assistant-part cache markers are hoisted to root cache_control. *)

(* --- Tool message tests (plan §4.6) --- *)

let mk_tool_result ?(po = PO.empty) ~id ~name ~result () : Ai_provider.Prompt.tool_result =
  { tool_call_id = id; tool_name = name; result; is_error = false; content = []; provider_options = po }

let test_tool_message_includes_name () =
  (* Plan §4.6: tool message includes a [name] field (new vs OpenAI converter). *)
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.Tool
         {
           content = [ mk_tool_result ~id:"call_1" ~name:"get_weather" ~result:(`String "sunny") () ];
         })
  in
  match json_field "name" json with
  | Some (`String "get_weather") -> ()
  | _ -> fail "expected name field on tool message"

let test_tool_message_no_cache () =
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.Tool
         {
           content = [ mk_tool_result ~id:"c" ~name:"t" ~result:(`String "ok") () ];
         })
  in
  match json with
  | `Assoc fs ->
    check bool "no cache_control field" true (Option.is_none (List.assoc_opt "cache_control" fs))
  | _ -> fail "assoc"

let test_tool_message_per_result_cache () =
  let po = CCO.with_cache_control ~cache_control:CC.ephemeral PO.empty in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.Tool
         {
           content = [ mk_tool_result ~po ~id:"c" ~name:"t" ~result:(`String "ok") () ];
         })
  in
  match json_field "cache_control" json with
  | Some (`Assoc _) -> ()
  | _ -> fail "expected cache_control on tool message from per-result po"

let test_tool_message_per_result_cache_with_ttl () =
  let po = CCO.with_cache_control ~cache_control:CC.ephemeral_1h PO.empty in
  let json =
    convert_one ~system_message_mode:System
      (Ai_provider.Prompt.Tool
         {
           content = [ mk_tool_result ~po ~id:"c" ~name:"t" ~result:(`String "ok") () ];
         })
  in
  match json_field "cache_control" json with
  | Some (`Assoc fs) ->
    (match List.assoc_opt "ttl" fs with
    | Some (`String "1h") -> ()
    | _ -> fail "expected ttl=1h")
  | _ -> fail "cache_control"

let test_tool_emits_one_per_result () =
  (* Each result emits one role:tool message (matches upstream loop). *)
  let msgs, _ =
    CP.convert_messages ~system_message_mode:System
      [
        Ai_provider.Prompt.Tool
          {
            content =
              [
                mk_tool_result ~id:"a" ~name:"t1" ~result:(`String "1") ();
                mk_tool_result ~id:"b" ~name:"t2" ~result:(`String "2") ();
              ];
          };
      ]
  in
  check int "two tool messages emitted" 2 (List.length msgs)

(* --- No-cache byte-equivalence regression (plan §13 acceptance criterion) --- *)

let test_byte_equivalence_no_cache_non_system () =
  (* A representative prompt without cache markers: user single text +
     assistant + tool. Must serialize to byte-equivalent JSON to a
     pre-change baseline. We pin the exact strings here as the contract. *)
  let msgs, _ =
    CP.convert_messages ~system_message_mode:System
      [
        Ai_provider.Prompt.User { content = [ Text { text = "Hi"; provider_options = PO.empty } ] };
        Ai_provider.Prompt.Assistant
          { content = [ Text { text = "Hello!"; provider_options = PO.empty } ] };
        Ai_provider.Prompt.Tool
          {
            content =
              [ mk_tool_result ~id:"call_1" ~name:"echo" ~result:(`String "Hi") () ];
          };
      ]
  in
  let serialized = List.map CP.openrouter_message_to_json msgs |> List.map Yojson.Basic.to_string in
  let expected =
    [
      {|{"role":"user","content":"Hi"}|};
      {|{"role":"assistant","content":"Hello!"}|};
      {|{"role":"tool","tool_call_id":"call_1","content":"Hi","name":"echo"}|};
    ]
  in
  let pair_check i (a, b) =
    check string (Printf.sprintf "msg %d byte-equal" i) b a
  in
  List.iteri pair_check (List.combine serialized expected)

let () =
  run "Convert_prompt"
    [
      ( "system",
        [
          test_case "no_cache_emits_array_form" `Quick test_system_no_cache_emits_array_form;
          test_case "with_cache_control" `Quick test_system_with_cache_control;
          test_case "anthropic_key_fallback" `Quick test_system_with_anthropic_fallback;
        ] );
      ( "user_single_text",
        [
          test_case "no_cache_emits_string" `Quick test_user_single_text_no_cache_emits_string;
          test_case "system_message_cache_sanity" `Quick test_user_single_text_message_cache;
          test_case "part_cache_flips_to_array" `Quick test_user_single_text_part_cache;
          test_case "public_serializer_with_cache" `Quick
            test_user_single_text_public_serializer_with_cache;
        ] );
      ( "user_multipart",
        [
          test_case "part_cache_only_on_second" `Quick test_user_multipart_part_cache_only;
          test_case "image_with_cache" `Quick test_user_multipart_image_with_cache;
          test_case "no_root_cache_control" `Quick test_user_multipart_no_root_cache;
        ] );
      ( "assistant",
        [
          test_case "no_cache_no_field" `Quick test_assistant_no_cache_no_field;
          test_case "with_tool_call_no_cache" `Quick test_assistant_with_tool_call_no_cache_no_field;
          test_case "text_part_cache_hoisted" `Quick test_assistant_text_part_cache_hoisted;
          test_case "tool_call_part_cache_hoisted" `Quick
            test_assistant_tool_call_part_cache_hoisted;
        ] );
      ( "tool",
        [
          test_case "includes_name_field" `Quick test_tool_message_includes_name;
          test_case "no_cache_no_field" `Quick test_tool_message_no_cache;
          test_case "per_result_cache" `Quick test_tool_message_per_result_cache;
          test_case "per_result_cache_with_ttl" `Quick test_tool_message_per_result_cache_with_ttl;
          test_case "one_message_per_result" `Quick test_tool_emits_one_per_result;
        ] );
      ( "regression",
        [
          test_case "byte_equivalence_no_cache_non_system" `Quick
            test_byte_equivalence_no_cache_non_system;
        ] );
    ]
