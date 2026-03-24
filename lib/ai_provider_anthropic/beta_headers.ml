let required_betas ~thinking ~has_pdf ~tool_streaming =
  List.concat
    [
      (if thinking then [ "interleaved-thinking-2025-05-14" ] else []);
      (if has_pdf then [ "pdfs-2024-09-25" ] else []);
      (if tool_streaming then [ "fine-grained-tool-streaming-2025-05-14" ] else []);
    ]

let merge_beta_headers ~user_headers ~required =
  let existing_betas =
    List.filter_map
      (fun (k, v) -> if String.equal (String.lowercase_ascii k) "anthropic-beta" then Some v else None)
      user_headers
  in
  let existing_values = List.concat_map (fun s -> String.split_on_char ',' s |> List.map String.trim) existing_betas in
  let all_betas = existing_values @ required in
  let seen = Hashtbl.create 16 in
  let deduped =
    List.filter
      (fun b ->
        if Hashtbl.mem seen b then false
        else begin
          Hashtbl.replace seen b ();
          true
        end)
      all_betas
  in
  let other_headers =
    List.filter (fun (k, _) -> not (String.equal (String.lowercase_ascii k) "anthropic-beta")) user_headers
  in
  match deduped with
  | [] -> other_headers
  | betas -> other_headers @ [ "anthropic-beta", String.concat "," betas ]
