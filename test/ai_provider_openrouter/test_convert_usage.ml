open Alcotest

let test_basic_usage () =
  let json =
    Yojson.Basic.from_string {|{"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150}|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let sdk_usage = Ai_provider_openrouter.Convert_usage.to_usage usage in
  (check int) "input_tokens" 100 sdk_usage.input_tokens;
  (check int) "output_tokens" 50 sdk_usage.output_tokens;
  (check (option int)) "total_tokens" (Some 150) sdk_usage.total_tokens

let test_usage_with_nested_details () =
  let json =
    Yojson.Basic.from_string
      {|{
        "prompt_tokens": 200,
        "completion_tokens": 100,
        "total_tokens": 300,
        "prompt_tokens_details": { "cached_tokens": 150 },
        "completion_tokens_details": { "reasoning_tokens": 30 },
        "cost": 0.005,
        "cost_details": { "upstream_inference_cost": 0.004 }
      }|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let metadata = Ai_provider_openrouter.Convert_usage.to_metadata usage in
  (check int) "cache_read_tokens" 150 metadata.cache_read_tokens;
  (check int) "reasoning_tokens" 30 metadata.reasoning_tokens;
  (check (option (float 0.))) "cost" (Some 0.005) metadata.cost;
  (check (option (float 0.))) "upstream_inference_cost" (Some 0.004) metadata.upstream_inference_cost

let test_usage_missing_details () =
  let json =
    Yojson.Basic.from_string {|{"prompt_tokens": 10, "completion_tokens": 5}|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let metadata = Ai_provider_openrouter.Convert_usage.to_metadata usage in
  (check int) "cache_read_tokens defaults" 0 metadata.cache_read_tokens;
  (check int) "reasoning_tokens defaults" 0 metadata.reasoning_tokens;
  (check (option (float 0.))) "cost" None metadata.cost;
  (check (option (float 0.))) "upstream_inference_cost" None metadata.upstream_inference_cost

let test_usage_total_tokens_computed () =
  let json =
    Yojson.Basic.from_string {|{"prompt_tokens": 10, "completion_tokens": 5}|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let sdk_usage = Ai_provider_openrouter.Convert_usage.to_usage usage in
  (check (option int)) "total_tokens computed" (Some 15) sdk_usage.total_tokens

let () =
  run "Convert_usage"
    [
      ( "convert_usage",
        [
          test_case "basic_usage" `Quick test_basic_usage;
          test_case "nested_details" `Quick test_usage_with_nested_details;
          test_case "missing_details" `Quick test_usage_missing_details;
          test_case "total_tokens_computed" `Quick test_usage_total_tokens_computed;
        ] );
    ]
