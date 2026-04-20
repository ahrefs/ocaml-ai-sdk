# Anthropic Provider Implementation Details

## Main Entry Points (lib/ai_provider_anthropic/)

### ai_provider_anthropic.ml(i)
Public API for creating Anthropic providers/models:

```ocaml
(* Create a provider factory *)
val create : ?api_key:string -> ?base_url:string -> ?headers:(string*string) list -> unit -> Ai_provider.Provider.t

(* Create a single language model *)
val language_model : ?api_key:string -> ?base_url:string -> ?headers:(string*string) list -> 
                     model:string -> unit -> Ai_provider.Language_model.t

(* Convenience: use ANTHROPIC_API_KEY env var + default base URL *)
val model : string -> Ai_provider.Language_model.t

(* Re-exports all submodules *)
```

## Configuration (lib/ai_provider_anthropic/config.ml(i))

```ocaml
type fetch_fn = url:string -> headers:(string*string) list -> body:string -> Yojson.Basic.t Lwt.t

type t = {
  api_key : string option;           (* Defaults to ANTHROPIC_API_KEY env var *)
  base_url : string;                 (* Defaults to "https://api.anthropic.com/v1" *)
  default_headers : (string * string) list;
  fetch : fetch_fn option;            (* Custom HTTP function for testing *)
}

val create : ?api_key:string -> ?base_url:string -> ?headers:(string*string) list -> ?fetch:fetch_fn -> unit -> t
val api_key_exn : t -> string         (* Raises if not configured *)
```

## Model Implementation (lib/ai_provider_anthropic/anthropic_model.ml)

Core implementation of `Language_model.S`:

```ocaml
val create : config:Config.t -> model:string -> Ai_provider.Language_model.t
```

The create function builds a first-class module implementing:
- `specification_version = "V3"`
- `provider = "anthropic"`
- `model_id = model`
- `generate opts` - Non-streaming call
- `stream opts` - Streaming call

### Request Preparation (prepare_request function)
1. Extract Anthropic-specific options from `Call_options.provider_options` using GADT
2. Check for unsupported features (frequency_penalty, presence_penalty, seed, temperature+thinking)
3. Extract system messages from prompt
4. Convert SDK messages to Anthropic format
5. Handle structured output mode: on models that support it (Haiku 4.5+, Sonnet 4.5+,
   Opus 4.5+), send native [output_config.format = json_schema]; otherwise synthesize a
   [json] tool with the schema as [input_schema] and force [tool_choice] to it. Gated on
   `Model_catalog.supports_structured_output`.
6. Convert tools to Anthropic format
7. Apply model-aware defaults for max_tokens
8. Extract thinking configuration
9. Build Anthropic API request body
10. Merge required beta headers

### Generate Flow
1. `prepare_request` with `stream:false`
2. Call `Anthropic_api.messages` 
3. Parse response with `Convert_response.parse_response`
4. Merge warnings with result

### Stream Flow
1. `prepare_request` with `stream:true`
2. Call `Anthropic_api.messages`
3. Parse SSE events with `Sse.parse_events`
4. Transform with `Convert_stream.transform`
5. Return as `Lwt_stream.t`

## Anthropic-Specific Options (lib/ai_provider_anthropic/anthropic_options.ml(i))

```ocaml
type structured_output_mode = Auto | Output_format | Json_tool

type t = {
  thinking : Thinking.t option;                   (* Extended thinking *)
  cache_control : Cache_control.t option;         (* Prompt caching *)
  tool_streaming : bool;                          (* Stream tool calls *)
  structured_output_mode : structured_output_mode;
}

val default : t
type _ Ai_provider.Provider_options.key += | Anthropic : t Ai_provider.Provider_options.key
val to_provider_options : t -> Ai_provider.Provider_options.t
val of_provider_options : Ai_provider.Provider_options.t -> t option
```

## Extended Thinking (lib/ai_provider_anthropic/thinking.ml(i))

```ocaml
type budget_tokens = private int
val budget : int -> (budget_tokens, string) result
val budget_exn : int -> budget_tokens  (* Raises if < 1024 *)
val to_int : budget_tokens -> int

type t = {
  enabled : bool;
  budget_tokens : budget_tokens;
}
```

## Model Catalog (lib/ai_provider_anthropic/model_catalog.ml(i))

Type-safe model selection with capabilities metadata:

```ocaml
type model_capabilities = {
  max_output_tokens : int;
  supports_thinking : bool;
  supports_structured_output : bool;
  supports_prompt_caching : bool;
  min_cache_tokens : int;
  supports_vision : bool;
  supports_pdf : bool;
}

type known_model =
  | Claude_opus_4_6
  | Claude_sonnet_4_6
  | Claude_haiku_4_5
  | Claude_sonnet_4_5
  | Claude_opus_4_5
  | Claude_opus_4_1
  | Claude_sonnet_4
  | Claude_opus_4
  | Custom of string

val to_model_id : known_model -> string
val of_model_id : string -> known_model
val capabilities : known_model -> model_capabilities
val default_max_tokens : known_model -> int
```

## Conversion Modules

### convert_prompt.ml(i)
Converts SDK prompts to Anthropic Messages API format:
- Defines Anthropic content block types (A_text, A_image, A_document, A_tool_use, A_tool_result, A_thinking)
- `extract_system : Ai_provider.Prompt.message list -> string option * Ai_provider.Prompt.message list`
- `convert_messages : Ai_provider.Prompt.message list -> anthropic_message list`
- Handles user/assistant role alternation
- JSON serialization: `anthropic_content_to_json`, `anthropic_message_to_json`

### convert_tools.ml(i)
Converts SDK tools to Anthropic format:
```ocaml
type anthropic_tool = {
  name : string;
  description : string option;
  input_schema : Yojson.Basic.t;
  cache_control : Cache_control.t option;
}

type anthropic_tool_choice = Tc_auto | Tc_any | Tc_tool { name }

val convert_tools : tools:Ai_provider.Tool.t list -> tool_choice:Ai_provider.Tool_choice.t option 
                    -> anthropic_tool list * anthropic_tool_choice option
```

### convert_response.ml(i)
Parses Anthropic Messages API JSON responses:
- `content_block_json` - Anthropic content block representation
- `anthropic_response_json` - Full Anthropic response
- `map_stop_reason : string option -> Ai_provider.Finish_reason.t`
- `parse_response : Yojson.Basic.t -> Ai_provider.Generate_result.t`

### convert_stream.ml(i)
Transforms Anthropic SSE events to SDK stream parts:
- Manages content block state for tool call arg accumulation
- `transform : Sse.event Lwt_stream.t -> warnings:Ai_provider.Warning.t list -> Ai_provider.Stream_part.t Lwt_stream.t`

### convert_usage.ml(i)
Maps Anthropic usage JSON to SDK `Usage.t`

## HTTP API (lib/ai_provider_anthropic/anthropic_api.ml(i))

```ocaml
val make_request_body : model:string -> messages:Convert_prompt.anthropic_message list 
                        -> ?system:string -> ?tools:Convert_tools.anthropic_tool list 
                        -> ?tool_choice:Convert_tools.anthropic_tool_choice
                        -> ?max_tokens:int -> ?temperature:float -> ?top_p:float -> ?top_k:int
                        -> ?stop_sequences:string list -> ?thinking:Thinking.t
                        -> ?stream:bool -> unit -> Yojson.Basic.t

val messages : config:Config.t -> body:Yojson.Basic.t -> extra_headers:(string*string) list 
               -> stream:bool -> [ `Json of Yojson.Basic.t | `Stream of string Lwt_stream.t ] Lwt.t
```

## SSE Streaming (lib/ai_provider_anthropic/sse.ml(i))

Server-sent events parsing:
```ocaml
type event = { event : string; data : Yojson.Basic.t }
val parse_events : string Lwt_stream.t -> event Lwt_stream.t
```

## Beta Headers (lib/ai_provider_anthropic/beta_headers.ml(i))

Manages Anthropic API beta feature headers:
- `required_betas : thinking:bool -> has_pdf:bool -> tool_streaming:bool -> string list`
- `merge_beta_headers : user_headers:(string*string) list -> required:string list -> (string*string) list`

## Caching Support (lib/ai_provider_anthropic/cache_control*.ml(i))

### cache_control.ml(i)
```ocaml
type t = {
  type_ : string;  (* "ephemeral" or other types *)
}
```

### cache_control_options.ml(i)
Per-content cache control hints
