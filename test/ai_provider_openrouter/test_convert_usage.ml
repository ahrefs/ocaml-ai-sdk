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

let test_usage_with_extended_fields () =
  let json =
    Yojson.Basic.from_string
      {|{
        "prompt_tokens": 200,
        "completion_tokens": 100,
        "total_tokens": 300,
        "cache_read_tokens": 150,
        "cache_write_tokens": 50,
        "reasoning_tokens": 30
      }|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let metadata = Ai_provider_openrouter.Convert_usage.to_metadata usage in
  (check int) "cache_read_tokens" 150 metadata.cache_read_tokens;
  (check int) "cache_write_tokens" 50 metadata.cache_write_tokens;
  (check int) "reasoning_tokens" 30 metadata.reasoning_tokens

let test_usage_missing_extended_fields () =
  let json =
    Yojson.Basic.from_string {|{"prompt_tokens": 10, "completion_tokens": 5}|}
  in
  let usage = Ai_provider_openrouter.Convert_usage.openrouter_usage_of_json json in
  let metadata = Ai_provider_openrouter.Convert_usage.to_metadata usage in
  (check int) "cache_read_tokens defaults" 0 metadata.cache_read_tokens;
  (check int) "cache_write_tokens defaults" 0 metadata.cache_write_tokens;
  (check int) "reasoning_tokens defaults" 0 metadata.reasoning_tokens

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
          test_case "extended_fields" `Quick test_usage_with_extended_fields;
          test_case "missing_extended_fields" `Quick test_usage_missing_extended_fields;
          test_case "total_tokens_computed" `Quick test_usage_total_tokens_computed;
        ] );
    ]
