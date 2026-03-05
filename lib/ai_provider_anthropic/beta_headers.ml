let required_betas ~thinking ~has_pdf ~tool_streaming =
  let betas = ref [] in
  if thinking then betas := "interleaved-thinking-2025-05-14" :: !betas;
  if has_pdf then betas := "pdfs-2024-09-25" :: !betas;
  if tool_streaming then betas := "fine-grained-tool-streaming-2025-05-14" :: !betas;
  List.rev !betas

let merge_beta_headers ~user_headers ~required =
  (* Find existing anthropic-beta header *)
  let existing_betas =
    List.filter_map (fun (k, v) -> if String.lowercase_ascii k = "anthropic-beta" then Some v else None) user_headers
  in
  let existing_values = List.concat_map (fun s -> String.split_on_char ',' s |> List.map String.trim) existing_betas in
  (* Merge and deduplicate *)
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
  (* Remove old anthropic-beta headers and add the merged one *)
  let other_headers = List.filter (fun (k, _) -> String.lowercase_ascii k <> "anthropic-beta") user_headers in
  match deduped with
  | [] -> other_headers
  | betas -> other_headers @ [ "anthropic-beta", String.concat "," betas ]
