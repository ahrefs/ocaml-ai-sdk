let empty_response : Ai_provider.Generate_result.response_info = { id = None; model = None; headers = []; body = `Null }

let make ?(response = empty_response) ?(warnings = []) ~finish_reason ~usage ~output steps =
  {
    Generate_text_result.text = Generate_text_result.join_text steps;
    reasoning = Generate_text_result.join_reasoning steps;
    tool_calls = List.concat_map (fun (s : Generate_text_result.step) -> s.tool_calls) steps;
    tool_results = List.concat_map (fun (s : Generate_text_result.step) -> s.tool_results) steps;
    steps;
    finish_reason;
    usage;
    response;
    warnings;
    output;
  }
