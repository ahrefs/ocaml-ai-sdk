type t = steps:Generate_text_result.step list -> bool Lwt.t

let step_count_is n ~steps = Lwt.return (List.compare_length_with steps n >= 0)

let rec last_opt = function
  | [] -> None
  | [ x ] -> Some x
  | _ :: tl -> last_opt tl

let has_tool_call tool_name ~(steps : Generate_text_result.step list) =
  match last_opt steps with
  | None -> Lwt.return false
  | Some last ->
    Lwt.return
      (List.exists (fun (tc : Generate_text_result.tool_call) -> String.equal tc.tool_name tool_name) last.tool_calls)

let is_met conditions ~steps = Lwt_list.exists_s (fun cond -> cond ~steps) conditions
