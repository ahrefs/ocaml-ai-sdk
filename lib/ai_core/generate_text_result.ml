type tool_call = {
  tool_call_id : string;
  tool_name : string;
  args : Yojson.Safe.t;
}

type tool_result = {
  tool_call_id : string;
  tool_name : string;
  result : Yojson.Safe.t;
  is_error : bool;
}

type step = {
  text : string;
  reasoning : string;
  tool_calls : tool_call list;
  tool_results : tool_result list;
  finish_reason : Ai_provider.Finish_reason.t;
  usage : Ai_provider.Usage.t;
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
}

let join_text steps =
  steps |> List.map (fun (s : step) -> s.text) |> List.filter (fun s -> String.length s > 0) |> String.concat "\n"

let join_reasoning steps =
  steps |> List.map (fun (s : step) -> s.reasoning) |> List.filter (fun s -> String.length s > 0) |> String.concat "\n"

let add_usage (a : Ai_provider.Usage.t) (b : Ai_provider.Usage.t) : Ai_provider.Usage.t =
  let input_tokens = a.input_tokens + b.input_tokens in
  let output_tokens = a.output_tokens + b.output_tokens in
  {
    input_tokens;
    output_tokens;
    total_tokens =
      (match a.total_tokens, b.total_tokens with
      | Some x, Some y -> Some (x + y)
      | _ -> Some (input_tokens + output_tokens));
  }
