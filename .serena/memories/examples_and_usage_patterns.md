# Examples & Usage Patterns

## Key Example Files

### examples/one_shot.ml
Basic non-streaming generation:
1. Create model via `Ai_provider_anthropic.model` with model ID
2. Build `Call_options.t` with:
   - System message
   - User message with text content
3. Call `Ai_provider.Language_model.generate`
4. Iterate over `result.content` for response parts
5. Access metadata: `result.response.model`, `result.finish_reason`, `result.usage`

### examples/generate.ml
High-level core API usage:
1. Select model from `Ai_provider_anthropic.Model_catalog`
2. Call `Ai_core.Generate_text.generate_text` with friendly parameters:
   - `~system` - System instruction string
   - `~prompt` - Prompt string (auto-converted to message)
3. Result includes text and metadata

### examples/streaming.ml
Streaming with event loop:
1. Get streaming language model
2. Build call options
3. Call `Ai_provider.Language_model.stream`
4. Consume `result.stream` with `Lwt_stream.iter`:
   - `Stream_start { warnings }`
   - `Text { text }` - Print immediately for responsiveness
   - `Reasoning { text }` - Extended thinking blocks
   - `Tool_call_delta { args_text_delta }` - Tool args streaming
   - `Finish { finish_reason, usage }`
   - `Error { error }`

### examples/tool_use.ml
Function calling:
1. Define tools as `Ai_provider.Tool.t` list with JSON Schema parameters
2. Build options with tools and `tool_choice`
3. Call generate/stream
4. Pattern match `Content.Tool_call` to handle invocations
5. In next message, send tool results via `Prompt.Tool` message

### examples/thinking.ml
Extended thinking:
1. Check `Model_catalog.capabilities model`.supports_thinking
2. Create `Thinking.t` with enabled=true and budget_tokens >= 1024
3. Wrap in `Anthropic_options` and convert to `Provider_options`
4. Pass through call options
5. Set `max_output_tokens > budget_tokens`
6. Response includes `Content.Reasoning` blocks before answer

## Common Patterns

### Pattern: Model Selection
```ocaml
(* Type-safe from catalog *)
let open Ai_provider_anthropic.Model_catalog in
let model = Claude_sonnet_4_6 in
let model_id = to_model_id model in
let caps = capabilities model in
(* Check caps.supports_thinking, etc *)

(* Or direct string *)
let model = Ai_provider_anthropic.model "claude-sonnet-4-6" in
```

### Pattern: Simple Prompt
```ocaml
let opts = Ai_provider.Call_options.default
  ~prompt:[
    System { content = "..." };
    User { content = [ Text { text = "..."; provider_options = empty } ] };
  ]
in
let result = Ai_provider.Language_model.generate model opts in
```

### Pattern: Tool Definition
```ocaml
let tool : Ai_provider.Tool.t = {
  name = "get_weather";
  description = Some "Get weather for city";
  parameters = `Assoc [
    "type", `String "object";
    "properties", `Assoc [
      "city", `Assoc [ "type", `String "string" ]
    ];
    "required", `List [ `String "city" ];
  ];
}
```

### Pattern: Structured Output (JSON)
```ocaml
let schema = { Mode.name = "Person"; schema = `Assoc [...] } in
let opts = { (Call_options.default ~prompt) with
  mode = Object_json (Some schema);
}
```

### Pattern: Anthropic-Specific Options
```ocaml
let anthropic_opts = {
  Ai_provider_anthropic.Anthropic_options.default with
  thinking = Some { enabled = true; budget_tokens = (Thinking.budget_exn 4096) };
  cache_control = Some { type_ = "ephemeral" };
  tool_streaming = true;
}
in
let provider_opts = Ai_provider_anthropic.Anthropic_options.to_provider_options anthropic_opts in
let opts = { (Call_options.default ~prompt) with provider_options = provider_opts }
```

## Error Handling

Provider operations return `Result` or raise exceptions:
- `Config.api_key_exn` - Raises if API key not configured
- `Thinking.budget_exn` - Raises if budget < 1024
- Network/API errors wrapped in `Provider_error.t`
- Warnings collected in result for non-fatal issues

## Multi-Step Tool Execution Pattern

The high-level Core SDK handles this automatically:
```ocaml
(* One call - SDK handles the loop *)
Ai_core.Generate_text.generate_text
  ~model
  ~prompt:"Do X with tool Y"
  ~tools:[("tool_y", tool_definition)]
  ~max_steps:5  (* Default loop limit *)
  ()
```

The function:
1. Calls model
2. If tool call in response, executes tool
3. Sends result back to model
4. Repeats until stop or max_steps reached
5. Returns final result with all steps
