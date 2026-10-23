type tool_call = {
  tool_call_id : string;
  tool_name : string;
  args : Yojson.Basic.t;
}

type pending_tool_approval = {
  tool_call_id : string;
  tool_name : string;
  args : Yojson.Basic.t;
  approved : bool;
}

type tool_result = {
  tool_call_id : string;
  tool_name : string;
  result : Yojson.Basic.t;
  is_error : bool;
  provider_metadata : Yojson.Basic.t option;
}

type step = {
  text : string;
  reasoning : string;
  tool_calls : tool_call list;
  tool_results : tool_result list;
  finish_reason : Ai_provider.Finish_reason.t;
  usage : Ai_provider.Usage.t;
  response_model : string option;
  provider_metadata : Ai_provider.Provider_options.t option;
}

type t = {
  text : string;
  reasoning : string;
  tool_calls : tool_call list;
  tool_results : tool_result list;
  steps : step list;
  finish_reason : Ai_provider.Finish_reason.t;
  usage : Ai_provider.Usage.t;
  response : Ai_provider.Generate_result.response_info;
  warnings : Ai_provider.Warning.t list;
  output : Yojson.Basic.t option;
}

let join_text steps =
  steps |> List.map (fun (s : step) -> s.text) |> List.filter (fun s -> String.length s > 0) |> String.concat "\n"

let join_reasoning steps =
  steps |> List.map (fun (s : step) -> s.reasoning) |> List.filter (fun s -> String.length s > 0) |> String.concat "\n"

(* A side with no total counts as its input plus output, so the sum does not
   depend on the order. *)
let add_usage (a : Ai_provider.Usage.t) (b : Ai_provider.Usage.t) : Ai_provider.Usage.t =
  let total (usage : Ai_provider.Usage.t) =
    Option.value usage.total_tokens ~default:(usage.input_tokens + usage.output_tokens)
  in
  {
    input_tokens = a.input_tokens + b.input_tokens;
    output_tokens = a.output_tokens + b.output_tokens;
    total_tokens = Some (total a + total b);
  }

let zero_usage : Ai_provider.Usage.t = { input_tokens = 0; output_tokens = 0; total_tokens = Some 0 }
let total_usage steps = List.fold_left (fun total (s : step) -> add_usage total s.usage) zero_usage steps
