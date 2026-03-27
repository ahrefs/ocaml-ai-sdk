# Complete File Reference & Architecture

## Directory Structure (Source Files Only)

```
lib/
├── ai_provider/                    (Base provider layer - 20+ files)
│   ├── ai_provider.ml(i)          Main module - re-exports all
│   ├── provider.ml(i)             Factory module type
│   ├── language_model.ml(i)       Core interface all models implement
│   ├── call_options.ml(i)         Unified call parameters
│   ├── generate_result.ml(i)      Non-streaming response type
│   ├── stream_result.ml(i)        Streaming response type
│   ├── stream_part.ml(i)          Individual stream events
│   ├── prompt.ml(i)               Role-constrained messages
│   ├── content.ml(i)              Response content types
│   ├── tool.ml(i)                 Tool definition
│   ├── tool_choice.ml(i)          Tool selection strategy
│   ├── mode.ml(i)                 Output mode (regular/json/tool)
│   ├── finish_reason.ml(i)        Why generation finished
│   ├── usage.ml(i)                Token counts
│   ├── provider_error.ml(i)       Error types from provider
│   ├── warning.ml(i)              Non-fatal issues
│   ├── provider_options.ml(i)     GADT for extensible options
│   ├── middleware.ml(i)           Cross-cutting concerns
│   └── dune
│
├── ai_provider_anthropic/          (Anthropic implementation - 33+ files)
│   ├── ai_provider_anthropic.ml(i)   Main entry point with factory functions
│   ├── anthropic_model.ml(i)         Language_model.S implementation
│   ├── config.ml(i)                  API key, base URL, HTTP config
│   ├── anthropic_api.ml(i)           HTTP client for Messages API
│   ├── anthropic_options.ml(i)       Extended options (thinking, cache, etc)
│   ├── anthropic_error.ml(i)         Anthropic-specific errors
│   ├── anthropic_model.ml(i)         Model catalog type
│   │
│   ├── model_catalog.ml(i)           Known models with capabilities
│   ├── thinking.ml(i)                Extended thinking config
│   ├── cache_control.ml(i)           Cache control headers
│   ├── cache_control_options.ml(i)   Per-content cache hints
│   ├── beta_headers.ml(i)            API feature beta headers
│   │
│   ├── convert_prompt.ml(i)          SDK prompts → Anthropic format
│   ├── convert_tools.ml(i)           SDK tools → Anthropic format
│   ├── convert_response.ml(i)        Anthropic response → SDK types
│   ├── convert_stream.ml(i)          SSE events → stream parts
│   ├── convert_usage.ml(i)           Usage JSON mapping
│   │
│   ├── sse.ml(i)                     Server-sent events parser
│   └── dune
│
└── ai_core/                          (High-level SDK - 17+ files)
    ├── ai_core.ml(i)                Main re-exports
    ├── generate_text.ml(i)          Non-streaming with tool loops
    ├── stream_text.ml(i)            Streaming with tool handling
    ├── generate_text_result.ml(i)   Result type with steps
    ├── stream_text_result.ml(i)     Streaming result
    ├── core_tool.ml(i)              Tool with execute function
    ├── output.ml(i)                 Structured output schema
    ├── prompt_builder.ml(i)         Fluent prompt construction
    ├── text_stream_part.ml(i)       Text-specific stream events
    ├── ui_message_chunk.ml(i)       Frontend message events
    ├── ui_message_stream.ml(i)      Frontend message protocol
    ├── partial_json.ml(i)           Streaming JSON parser
    ├── server_handler.ml(i)         HTTP streaming server utils
    └── dune

examples/
├── dune
├── one_shot.ml          Non-streaming basic generation
├── generate.ml          High-level Core SDK usage
├── streaming.ml         Streaming with Lwt_stream
├── tool_use.ml          Function calling example
├── thinking.ml          Extended thinking
├── stream_chat.ml       Chat-based streaming
└── chat_server/         Full chat server example

test/
├── ai_provider/         Provider interface tests
├── ai_provider_anthropic/  Anthropic-specific tests
└── ai_core/             Core SDK tests

bin/                     CLI tools (if any)
bindings/               Melange React bindings

Root:
├── dune-project         Project & package definitions
├── Makefile            Make targets for development
├── .ocamlformat        OCaml formatting rules
└── CLAUDE.md           Code style guidelines
```

## Module Type Hierarchy

```
Language_model.S (core interface implemented by each provider)
  ├── specification_version : string
  ├── provider : string
  ├── model_id : string
  ├── generate : Call_options.t -> Generate_result.t Lwt.t
  └── stream : Call_options.t -> Stream_result.t Lwt.t

Provider.S (factory)
  ├── name : string
  └── language_model : string -> Language_model.t

Middleware.S (cross-cutting concerns)
  ├── wrap_generate : ...
  └── wrap_stream : ...
```

## Type Flow Diagram

```
Call_options.t (input)
├── prompt: Prompt.message list
│   ├── System, User, Assistant, Tool variants
│   └── Each variant constrains content types
├── mode: Mode.t (Regular/Object_json/Object_tool)
├── tools: Tool.t list
├── tool_choice: Tool_choice.t option
├── provider_options: Provider_options.t (GADT)
└── ... other params (temperature, max_tokens, etc)

↓ (call Language_model.generate or .stream)

Generate_result.t (or Stream_result.t)
├── content: Content.t list
│   ├── Text, Tool_call, Reasoning, File variants
├── finish_reason: Finish_reason.t
├── usage: Usage.t
├── warnings: Warning.t list
└── metadata: response_info
```

## Key Design Patterns

### 1. First-Class Modules for Runtime Dispatch
```ocaml
type Language_model.t = (module Language_model.S)
type Provider.t = (module Provider.S)
```
Allows runtime provider selection while maintaining type safety.

### 2. GADT for Extensible Provider Options
```ocaml
type _ Provider_options.key = ..
type Provider_options.entry = Entry : 'a key * 'a -> entry
type Provider_options.t = entry list
```
Each provider adds typed keys without circular dependencies.

### 3. Role-Constrained Messages
```ocaml
type Prompt.message =
  | System of { content : string }           (* text only *)
  | User of { content : user_part list }    (* text/files *)
  | Assistant of { content : assistant_part list }  (* text/files/reasoning/tools *)
  | Tool of { content : tool_result list }  (* tool results only *)
```
Type system ensures only valid content types per role.

### 4. Streaming via Lwt_stream
```ocaml
Stream_result.t = {
  stream : Stream_part.t Lwt_stream.t;  (* Lazy event stream *)
  warnings : Warning.t list;
  raw_response : ...
}
```
Efficient memory usage for long-running streams.

### 5. Modular Conversion Layers
Each provider has:
- `convert_prompt` - SDK → Provider format
- `convert_tools` - SDK → Provider format
- `convert_response` - Provider → SDK format
- `convert_stream` - Provider events → SDK events

Keeps provider logic isolated and testable.

## Anthropic-Specific Implementation Details

### Request Path (generate)
1. User calls `Anthropic_model.create ~config ~model` → `Language_model.t`
2. User calls `Language_model.generate call_options` 
3. `anthropic_model.ml` checks unsupported features
4. Converts SDK call to Anthropic request:
   - Prompts via `Convert_prompt.convert_messages`
   - Tools via `Convert_tools.convert_tools`
   - Structured output mode → system prompt injection
   - Beta headers via `Beta_headers.required_betas`
5. Calls `Anthropic_api.messages` with JSON body
6. Parses response via `Convert_response.parse_response`
7. Returns `Generate_result.t`

### Stream Path
Similar to above but:
- Response is SSE (server-sent events)
- `Sse.parse_events` converts lines to events
- `Convert_stream.transform` maps events to `Stream_part.t`
- Returns `Stream_result.t` with `stream : Stream_part.t Lwt_stream.t`

### Config Resolution
- API key: Explicit parameter → environment variable `ANTHROPIC_API_KEY`
- Base URL: Explicit parameter → `https://api.anthropic.com/v1`
- Custom fetch: For testing, override HTTP implementation

## No OpenAI Implementation

The codebase currently only implements Anthropic provider. No `ai_provider_openai` directory exists.

The architecture is designed to support adding OpenAI later:
1. Create `lib/ai_provider_openai/`
2. Implement `Language_model.S` with OpenAI API
3. Handle OpenAI-specific options via GADT extension
4. Implement conversion modules similar to Anthropic
5. Export via `Ai_provider_openai` module
