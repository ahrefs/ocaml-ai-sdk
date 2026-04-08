# Core SDK Layer (lib/ai_core) & Shared Utilities

## AI Core Module Overview (lib/ai_core/ai_core.mli)

High-level abstractions built on top of base provider layer:

### Core Components

**Generate_text** - Non-streaming with multi-step tool execution:
```ocaml
val generate_text : model:Ai_provider.Language_model.t
  -> ?system:string
  -> ?prompt:string
  -> ?messages:Ai_provider.Prompt.message list
  -> ?tools:(string * Core_tool.t) list
  -> ?tool_choice:Ai_provider.Tool_choice.t
  -> ?output:(Yojson.Basic.t, Yojson.Basic.t) Output.t
  -> ?max_steps:int
  -> ?max_output_tokens:int
  -> ?temperature:float
  -> ?top_p:float
  -> ?top_k:int
  -> ?stop_sequences:string list
  -> ?seed:int
  -> ?headers:(string*string) list
  -> ?provider_options:Ai_provider.Provider_options.t
  -> ?on_step_finish:(Generate_text_result.step -> unit)
  -> unit
  -> Generate_text_result.t Lwt.t
```

Features:
- Multi-step tool execution (loops until tool use stops)
- Structured output validation
- Step callbacks for progress tracking
- Automatic prompt conversion from string to message list

**Stream_text** - Streaming generation with tool handling

**Prompt_builder** - Fluent prompt construction

**Core_tool** - Tool definitions with execution functions:
```ocaml
type t = {
  description : string option;
  parameters : Yojson.Basic.t;  (* JSON Schema *)
  execute : Yojson.Basic.t -> (Yojson.Basic.t, string) result Lwt.t;
}
```

**Output** - Structured output schema definition (generics for input/output validation)

**UIMessage Protocol** - Frontend interoperability:
- `Ui_message_chunk.t` - Individual message events
- `Ui_message_stream.t` - Full message stream protocol
- `Text_stream_part.t` - Text token streaming

**Server_handler** - HTTP server utilities for streaming endpoints

**Partial_json** - Streaming JSON parser for partial tool arguments

## Shared Provider Types & Utilities

### Mode.t (lib/ai_provider/mode.mli)
Controls output format:
```ocaml
type json_schema = { name : string; schema : Yojson.Basic.t }

type t =
  | Regular                           (* Default mode *)
  | Object_json of json_schema option (* Structured JSON output *)
  | Object_tool of {                  (* Structured output as tool call *)
      tool_name : string;
      schema : json_schema;
    }
```

### Provider_error.t (lib/ai_provider/provider_error.mli)
Error representation from providers:
- `Network_error { message : string; error_code : string }`
- `Auth_error { message : string }`
- `Validation_error { message : string }`
- `Rate_limit_error { message : string; retry_after : float }`
- `Model_not_found { message : string; model_id : string }`
- `Other { message : string; error_code : string }`

### Warning.t (lib/ai_provider/warning.mli)
Non-fatal issues to report to caller:
- `Unsupported_feature { feature : string; details : string option }`

### Finish_reason.t
Mapped to SDK-agnostic values; each provider maps its own stop reasons

### Usage.t
```ocaml
type t = {
  input_tokens : int;
  output_tokens : int;
  total_tokens : int option;
}
```

## Dune Configuration

### lib/ai_provider/dune
```
(library
 (name ai_provider)
 (public_name ocaml-ai-sdk.ai_provider)
 (libraries lwt yojson melange-json-native)
 (preprocess (pps melange-json-native.ppx ppx_deriving.show)))
```

### lib/ai_provider_anthropic/dune
```
(library
 (name ai_provider_anthropic)
 (public_name ocaml-ai-sdk.ai_provider_anthropic)
 (libraries ai_provider lwt lwt.unix cohttp-lwt-unix yojson 
            melange-json-native base64)
 (preprocess (pps lwt_ppx melange-json-native.ppx ppx_deriving.show)))
```

Key Dependencies:
- `cohttp-lwt-unix` - HTTP client
- `base64` - Encoding file data
- `lwt_ppx` - Async syntax

### lib/ai_core/dune
(library name ai_core, similar PPX setup, depends on ai_provider)

## Module Exports

### ai_provider.mli re-exports:
- Provider_options, Finish_reason, Usage, Warning
- Provider_error, Prompt, Tool, Tool_choice, Mode, Content
- Call_options, Generate_result, Stream_part, Stream_result
- Language_model, Provider, Middleware

### ai_provider_anthropic.mli re-exports:
- Config, Model_catalog, Thinking, Cache_control, Anthropic_options
- Cache_control_options, Convert_prompt, Convert_tools, Convert_response
- Convert_usage, Anthropic_error, Sse, Convert_stream
- Beta_headers, Anthropic_api, Anthropic_model

### ai_core.mli re-exports:
- Core_tool, Generate_text_result, Text_stream_part
- Ui_message_chunk, Prompt_builder, Ui_message_stream
- Generate_text, Stream_text_result, Stream_text
- Server_handler, Partial_json, Output
