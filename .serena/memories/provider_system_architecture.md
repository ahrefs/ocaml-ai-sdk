# Provider System Architecture

## Core Provider Interfaces

### Language_model.S (lib/ai_provider/language_model.mli)
The main interface every provider must implement:
```ocaml
module type S = sig
  val specification_version : string  (* e.g., "V3" *)
  val provider : string               (* e.g., "anthropic" *)
  val model_id : string               (* e.g., "claude-sonnet-4-6" *)
  val generate : Call_options.t -> Generate_result.t Lwt.t
  val stream : Call_options.t -> Stream_result.t Lwt.t
end
```

First-class module wrapper: `type t = (module S)`

### Provider.S (lib/ai_provider/provider.mli)
Factory for creating language models from a provider:
```ocaml
module type S = sig
  val name : string
  val language_model : string -> Language_model.t
end

type t = (module S)
```

## Input/Output Types

### Call_options.t (lib/ai_provider/call_options.mli)
Unified input for both generate and stream:
- `prompt : Prompt.message list` - System/User/Assistant/Tool messages
- `mode : Mode.t` - Regular, Object_json, Object_tool
- `tools : Tool.t list` - Available functions
- `tool_choice : Tool_choice.t option` - Auto/Required/None_/Specific
- `max_output_tokens : int option`
- `temperature, top_p, top_k, stop_sequences`
- `seed, frequency_penalty, presence_penalty`
- `provider_options : Provider_options.t` - Provider-specific settings
- `headers : (string * string) list` - Custom HTTP headers
- `abort_signal : unit Lwt.t option` - Cancellation

### Generate_result.t (lib/ai_provider/generate_result.mli)
Non-streaming response:
- `content : Content.t list` - Text, tool calls, reasoning, files
- `finish_reason : Finish_reason.t` - Stop/Length/Tool_calls/Content_filter/Error/Other
- `usage : Usage.t` - Token counts
- `warnings : Warning.t list` - Implementation warnings
- `provider_metadata : Provider_options.t`
- `request, response : *_info` - Request/response metadata with JSON bodies

### Stream_result.t (lib/ai_provider/stream_result.mli)
Streaming response:
- `stream : Stream_part.t Lwt_stream.t` - Streamed parts
- `warnings : Warning.t list`
- `raw_response : Generate_result.response_info option`

### Stream_part.t (lib/ai_provider/stream_part.mli)
Individual streamed events:
- `Stream_start { warnings }` - Initial metadata
- `Text { text }` - Text token chunk
- `Reasoning { text }` - Thinking/extended thinking
- `Tool_call_delta { tool_call_type, tool_call_id, tool_name, args_text_delta }`
- `Tool_call_finish { tool_call_id }`
- `File { data, media_type }`
- `Finish { finish_reason, usage }`
- `Error { error }`
- `Provider_metadata { metadata }`

## Prompt and Content Types

### Prompt.message (lib/ai_provider/prompt.mli)
Role-constrained message types:
- `System { content : string }` - System instructions
- `User { content : user_part list }` - User input with text/files
- `Assistant { content : assistant_part list }` - Assistant response with text/files/reasoning/tool_calls
- `Tool { content : tool_result list }` - Tool execution results

### Content.t (lib/ai_provider/content.mli)
Response content parts:
- `Text { text }`
- `Tool_call { tool_call_type, tool_call_id, tool_name, args }`
- `Reasoning { text, signature, provider_options }`
- `File { data, media_type }`

## Extensibility: Provider_options.t (GADT)

Type-safe extensible options using GADT:
```ocaml
type _ key = ..
type entry = Entry : 'a key * 'a -> entry
type t = entry list
```

Each provider adds a typed key:
```ocaml
type _ Ai_provider.Provider_options.key +=
  | Anthropic : t Ai_provider.Provider_options.key
```

Allows type-safe passage of provider-specific options through generic SDK without circular deps.

## Middleware Support

### Middleware.S (lib/ai_provider/middleware.mli)
Wraps generate/stream with cross-cutting concerns:
```ocaml
module type S = sig
  val wrap_generate : ...
  val wrap_stream : ...
end
```

Can implement logging, caching, retries, etc.

## Tools & Tool Choice

### Tool.t (lib/ai_provider/tool.mli)
```ocaml
type t = {
  name : string;
  description : string option;
  parameters : Yojson.Basic.t;  (* JSON Schema *)
}
```

### Tool_choice.t (lib/ai_provider/tool_choice.mli)
- `Auto` - Model decides when to use tools
- `Required` - Model must call a tool
- `None_` - Never use tools
- `Specific { tool_name }` - Specific tool only

## Finish Reasons (lib/ai_provider/finish_reason.mli)

- `Stop` - Model stopped naturally
- `Length` - Hit max tokens
- `Tool_calls` - Model called a tool
- `Content_filter` - Filtered by safety policy
- `Error` - Internal error
- `Other of string` - Provider-specific
- `Unknown` - Unexpected value
