# Anthropic Provider Implementation Design

## Goal

Implement the Anthropic provider for the OCaml AI SDK — the concrete module that
satisfies the `Language_model.S` and `Provider.S` signatures defined in the
provider abstraction layer. This is the OCaml equivalent of Vercel AI SDK's
`@ai-sdk/anthropic` package.

---

## 1. Module Structure

```
lib/
  ai_provider_anthropic/
    ai_provider_anthropic.ml    -- top-level re-exports and factory
    config.ml                   -- provider configuration
    model_catalog.ml            -- known models and capabilities
    anthropic_model.ml          -- Language_model.S implementation
    convert_prompt.ml           -- SDK prompt -> Anthropic messages format
    convert_tools.ml            -- SDK tools -> Anthropic tool format
    convert_response.ml         -- Anthropic response -> SDK result
    convert_stream.ml           -- SSE stream -> SDK stream parts
    convert_usage.ml            -- Anthropic usage -> SDK usage
    anthropic_api.ml            -- HTTP client (messages endpoint)
    anthropic_error.ml          -- Anthropic-specific error handling
    cache_control.ml            -- prompt caching support
    thinking.ml                 -- extended thinking/reasoning support
```

---

## 2. Configuration (`Config`)

```ocaml
type t = {
  api_key : string;
  base_url : string;
  default_headers : (string * string) list;
  fetch : fetch_fn option;  (** custom HTTP function for testing *)
}

and fetch_fn =
  url:string ->
  headers:(string * string) list ->
  body:string ->
  Yojson.Safe.t Lwt.t

val create :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  ?fetch:fetch_fn ->
  unit -> t
(** Creates config. [api_key] defaults to [ANTHROPIC_API_KEY] env var.
    [base_url] defaults to ["https://api.anthropic.com/v1"]. *)

val api_key_exn : t -> string
(** Raises if no API key is configured. *)
```

**Why `fetch_fn` option:** Allows injecting a mock HTTP function for testing
without needing to spin up a server. The `option` means production code uses
the real HTTP client by default.

**Why `api_key` from env:** Follows the same convention as the TypeScript SDK.
Users can override explicitly, but the default "just works" if the env var is set.

---

## 3. Model Catalog (`Model_catalog`)

Known models with their capabilities, used for validation and defaults:

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
  (* Current generation *)
  | Claude_opus_4_6          (** claude-opus-4-6 — 128K max output *)
  | Claude_sonnet_4_6        (** claude-sonnet-4-6 — 64K max output *)
  | Claude_haiku_4_5         (** claude-haiku-4-5-20251001 — 64K max output *)
  (* Legacy (still available) *)
  | Claude_sonnet_4_5        (** claude-sonnet-4-5-20250929 *)
  | Claude_opus_4_5          (** claude-opus-4-5-20251101 *)
  | Claude_opus_4_1          (** claude-opus-4-1-20250805 *)
  | Claude_sonnet_4           (** claude-sonnet-4-20250514 *)
  | Claude_opus_4             (** claude-opus-4-20250514 *)
  (* Escape hatch *)
  | Custom of string

val to_model_id : known_model -> string
val of_model_id : string -> known_model
val capabilities : known_model -> model_capabilities
val default_max_tokens : known_model -> int
```

**Why a variant for known models:** This gives us exhaustive pattern matching
for capability checks. `Custom of string` is the escape hatch for new models
we haven't catalogued yet — they get conservative defaults.

**Why this matters:** When a user enables thinking on a model that doesn't
support it, we can raise a clear error at configuration time rather than getting
a cryptic 400 from the API.

**Model list validated against Anthropic docs (March 2026).** Current gen:
Opus 4.6, Sonnet 4.6, Haiku 4.5. Legacy: Sonnet 4.5, Opus 4.5, Opus 4.1,
Sonnet 4, Opus 4. Claude 3 Haiku is deprecated (retiring April 2026) — omitted.

---

## 4. Anthropic-Specific Types

### 4.1 Thinking Configuration (`Thinking`)

```ocaml
type budget_tokens = private int
(** Thinking budget — always >= 1024 tokens. Private type enforces the
    invariant via smart constructor. *)

val budget : int -> (budget_tokens, string) result
(** Returns [Error] if budget < 1024. *)

val budget_exn : int -> budget_tokens
(** Raises [Invalid_argument] if budget < 1024. *)

type t = {
  enabled : bool;
  budget_tokens : budget_tokens;
}
```

**Why `private int`:** Anthropic requires a minimum of 1024 tokens for thinking
budget. A private type with a smart constructor makes it **impossible** to
construct an invalid budget. The compiler enforces the invariant — no runtime
checks needed downstream.

### 4.2 Cache Control (`Cache_control`)

```ocaml
type breakpoint = Ephemeral
(** Currently Anthropic only supports "ephemeral" cache type. Using a variant
    instead of a string means we can extend later without breaking code. *)

type t = { cache_type : breakpoint }

val ephemeral : t
```

**Why a variant instead of string:** The TypeScript SDK uses `"ephemeral"` as
a string literal. In OCaml we model it as a variant so the compiler catches
typos and we can add new cache types later.

### 4.3 Anthropic Provider Options

These are the Anthropic-specific options, registered via the extensible GADT:

```ocaml
module Anthropic_options : sig
  type structured_output_mode =
    | Auto          (** check model capabilities — use output_format if supported *)
    | Output_format (** always use native output_format *)
    | Json_tool     (** always use synthetic JSON tool *)

  type t = {
    thinking : Thinking.t option;
    cache_control : Cache_control.t option;
    tool_streaming : bool;  (** default: true *)
    structured_output_mode : structured_output_mode;  (** default: Auto *)
  }

  val default : t

  (** GADT key for Provider_options. *)
  type _ Provider_options.key += Anthropic : t Provider_options.key

  (** Convenience: wrap into Provider_options.t *)
  val to_provider_options : t -> Provider_options.t

  (** Convenience: extract from Provider_options.t *)
  val of_provider_options : Provider_options.t -> t option
end
```

### 4.4 Cache Control Typed Accessors

For setting cache control on individual prompt parts via `Provider_options.t`:

```ocaml
module Cache_control_options : sig
  (** GADT key for per-part cache control. *)
  type _ Provider_options.key +=
    | Cache : Cache_control.t Provider_options.key

  val with_cache_control :
    ?cache_control:Cache_control.t ->
    Provider_options.t -> Provider_options.t
  (** Adds cache control to a provider options bag. The optional labeled
      argument makes it ergonomic at construction sites:
      [User_part.Text { text = "...";
        provider_options = Cache_control_options.with_cache_control
          ~cache_control:Cache_control.ephemeral
          Provider_options.empty }] *)

  val get_cache_control : Provider_options.t -> Cache_control.t option
end
```

**Why separate from `Anthropic_options`:** Cache control is per-content-part,
while `Anthropic_options` is per-request. They live at different granularities
in the prompt structure. Using a separate GADT key keeps them independent.

---

## 5. Prompt Conversion (`Convert_prompt`)

Transforms `Prompt.message list` into Anthropic's messages API format.

### 5.1 Core Conversion

```ocaml
type anthropic_message = {
  role : [ `User | `Assistant ];
  content : anthropic_content list;
}

and anthropic_content =
  | A_text of { text : string; cache_control : Cache_control.t option }
  | A_image of { source : image_source; cache_control : Cache_control.t option }
  | A_document of { source : document_source; cache_control : Cache_control.t option }
  | A_tool_use of { id : string; name : string; input : Yojson.Safe.t }
  | A_tool_result of { tool_use_id : string; content : anthropic_tool_result_content list;
                        is_error : bool }
  | A_thinking of { thinking : string; signature : string }

and image_source =
  | Base64_image of { media_type : string; data : string }
  | Url_image of { url : string }

and document_source =
  | Base64_document of { media_type : string; data : string }

and anthropic_tool_result_content =
  | Tool_text of string
  | Tool_image of { source : image_source }

val convert :
  system_message:string option ->
  messages:Prompt.message list ->
  (string option * anthropic_message list, Provider_error.t) result
```

### 5.2 Message Grouping

Anthropic requires strictly alternating user/assistant messages. The converter
handles this by grouping consecutive same-role messages:

```ocaml
val group_messages : Prompt.message list -> anthropic_message list
(** Groups consecutive same-role messages. Inserts empty assistant/user
    messages where needed to maintain alternation. *)
```

**Why handle this in the converter:** This is a provider-specific constraint.
The abstraction layer allows any sequence of messages. The Anthropic converter
normalizes it. This way the user doesn't need to know about Anthropic's quirks.

### 5.3 System Message Extraction

Anthropic uses a top-level `system` parameter, not a system role in messages:

```ocaml
val extract_system : Prompt.message list -> string option * Prompt.message list
(** Extracts system messages and returns the rest. Multiple system messages
    are concatenated with newlines. *)
```

---

## 6. Tool Conversion (`Convert_tools`)

```ocaml
type anthropic_tool = {
  name : string;
  description : string option;
  input_schema : Yojson.Safe.t;
  cache_control : Cache_control.t option;
}

type anthropic_tool_choice =
  | Tc_auto
  | Tc_any    (** Anthropic's "required" equivalent *)
  | Tc_tool of { name : string }

val convert_tools :
  tools:Tool.t list ->
  tool_choice:Tool_choice.t option ->
  anthropic_tool list * anthropic_tool_choice option
```

**Mapping notes:**
- SDK `Required` -> Anthropic `any` (naming difference)
- SDK `None_` -> omit tools entirely from request
- SDK `Specific { tool_name }` -> Anthropic `tool { name }`

---

## 7. Response Conversion (`Convert_response`)

### 7.1 Non-Streaming

```ocaml
type anthropic_response = {
  id : string;
  model : string;
  content : anthropic_response_block list;
  stop_reason : string option;
  usage : anthropic_usage;
}

and anthropic_response_block =
  | Resp_text of { text : string }
  | Resp_tool_use of { id : string; name : string; input : Yojson.Safe.t }
  | Resp_thinking of { thinking : string; signature : string }

and anthropic_usage = {
  input_tokens : int;
  output_tokens : int;
  cache_read_input_tokens : int option;
  cache_creation_input_tokens : int option;
}

val to_generate_result :
  anthropic_response ->
  request_body:Yojson.Safe.t ->
  warnings:Warning.t list ->
  Generate_result.t
```

### 7.2 Finish Reason Mapping

```ocaml
val map_stop_reason : string option -> Finish_reason.t
(** "end_turn" -> Stop, "max_tokens" -> Length,
    "tool_use" -> Tool_calls, _ -> Other *)
```

---

## 8. Streaming (`Convert_stream`)

### 8.1 SSE Event Types

Anthropic uses Server-Sent Events with typed events:

```ocaml
type sse_event =
  | Message_start of { message : anthropic_response_header }
  | Content_block_start of { index : int; content_block : content_block_start }
  | Content_block_delta of { index : int; delta : content_delta }
  | Content_block_stop of { index : int }
  | Message_delta of { delta : message_delta; usage : anthropic_usage option }
  | Message_stop
  | Ping
  | Error of { error_type : string; message : string }

and anthropic_response_header = {
  id : string;
  model : string;
  usage : anthropic_usage;
}

and content_block_start =
  | Text_start
  | Tool_use_start of { id : string; name : string }
  | Thinking_start

and content_delta =
  | Text_delta of { text : string }
  | Input_json_delta of { partial_json : string }
  | Thinking_delta of { thinking : string }
  | Signature_delta of { signature : string }

and message_delta = {
  stop_reason : string option;
}
```

**Why model every SSE event as a variant:** This gives us exhaustive matching
on the stream. If Anthropic adds a new event type, deserialization produces an
`Error` or we add the variant — no silent data loss.

### 8.2 Stream Transformer

```ocaml
val transform_stream :
  sse_event Lwt_stream.t ->
  warnings:Warning.t list ->
  Stream_part.t Lwt_stream.t
(** Transforms raw SSE events into SDK-normalized stream parts.
    Manages content block state (accumulating tool call args, etc.). *)
```

### 8.3 SSE Parser

```ocaml
val parse_sse_line : string -> (sse_event option, string) result
(** Parses a single SSE line. Returns None for comments/empty lines. *)

val sse_stream_of_lines : string Lwt_stream.t -> sse_event Lwt_stream.t
(** Converts a line stream into an SSE event stream. Handles multi-line
    data fields and event type prefixes. *)
```

---

## 9. HTTP Client (`Anthropic_api`)

Uses `cohttp-lwt-unix` for HTTP. Chosen because:
- Compatible with OCaml 4.14 (project's current version)
- Integrates with Lwt ecosystem (matching `claude-agent-sdk` patterns)
- Battle-tested, widely used in production OCaml code
- `piaf` was considered but requires OCaml >= 5.1 and Eio — incompatible
- HTTP/2 (piaf's advantage) is irrelevant for SSE (chunked HTTP/1.1)

For streaming, `cohttp-lwt-unix` provides the response body which we drain
line-by-line into a `string Lwt_stream.t`, then parse SSE events — same
pattern as `claude-agent-sdk`'s subprocess stdout reader.

```ocaml
val messages :
  config:Config.t ->
  body:Yojson.Safe.t ->
  extra_headers:(string * string) list ->
  stream:bool ->
  [ `Json of Yojson.Safe.t | `Stream of string Lwt_stream.t ] Lwt.t

val make_request_body :
  model:string ->
  messages:anthropic_message list ->
  ?system:string ->
  ?tools:anthropic_tool list ->
  ?tool_choice:anthropic_tool_choice ->
  ?max_tokens:int ->
  ?temperature:float ->
  ?top_p:float ->
  ?top_k:int ->
  ?stop_sequences:string list ->
  ?thinking:Thinking.t ->
  ?stream:bool ->
  unit -> Yojson.Safe.t
```

**Why return a variant for messages:** The same endpoint is used for both
streaming and non-streaming. The return type makes it clear which case the
caller is in, and prevents accidentally trying to parse a stream as JSON.

---

## 10. The Model Implementation (`Anthropic_model`)

This ties everything together:

```ocaml
module Make (Cfg : sig val config : Config.t val model : Model_catalog.known_model end)
  : Language_model.S

(** Or, for runtime construction: *)
val create : config:Config.t -> model:string -> Language_model.t
```

The `generate` implementation:

1. Extract system message from prompt
2. Convert remaining messages via `Convert_prompt`
3. Convert tools via `Convert_tools`
4. Build request body via `Anthropic_api.make_request_body`
5. Apply provider options (thinking, cache control)
6. Call `Anthropic_api.messages ~stream:false`
7. Parse response and convert via `Convert_response.to_generate_result`
8. Return `Generate_result.t`

The `stream` implementation:

1. Steps 1-5 same as above
2. Call `Anthropic_api.messages ~stream:true`
3. Parse SSE stream via `Convert_stream.sse_stream_of_lines`
4. Transform via `Convert_stream.transform_stream`
5. Return `Stream_result.t`

---

## 11. The Provider Factory (`Ai_provider_anthropic`)

```ocaml
val create :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  unit -> Provider.t

(** Convenience: create a language model directly. *)
val language_model :
  ?api_key:string ->
  ?base_url:string ->
  model:string ->
  unit -> Language_model.t

(** Most common usage — just give me a model. *)
val model : string -> Language_model.t
(** Uses ANTHROPIC_API_KEY env var and default base URL. *)
```

**Usage examples:**

```ocaml
(* Simplest usage *)
let claude = Ai_provider_anthropic.model "claude-sonnet-4-20250514"

(* With configuration *)
let claude =
  Ai_provider_anthropic.language_model
    ~api_key:"sk-..."
    ~model:"claude-sonnet-4-20250514"
    ()

(* Via provider factory *)
let provider = Ai_provider_anthropic.create ~api_key:"sk-..." ()
let claude = Provider.language_model provider "claude-sonnet-4-20250514"
```

---

## 12. Error Handling

### 12.1 Anthropic API Errors

```ocaml
type anthropic_error_type =
  | Invalid_request_error
  | Authentication_error
  | Permission_error
  | Not_found_error
  | Rate_limit_error
  | Api_error
  | Overloaded_error

type anthropic_error = {
  error_type : anthropic_error_type;
  message : string;
}

val of_response : status:int -> body:string -> Provider_error.t
(** Parses Anthropic error response and wraps in Provider_error. *)

val is_retryable : anthropic_error_type -> bool
(** Rate_limit_error and Overloaded_error are retryable. *)
```

**Why a variant for error types:** Instead of string comparison, we parse
Anthropic's error type into a variant. This makes `is_retryable` a simple
pattern match and prevents typos.

### 12.2 Warnings

The implementation emits warnings for unsupported features:

```ocaml
val check_unsupported :
  Call_options.t -> Warning.t list
(** Checks for features Anthropic doesn't support:
    - frequency_penalty -> Unsupported_feature
    - presence_penalty -> Unsupported_feature
    - seed (limited support) -> Unsupported_feature *)
```

---

## 13. Beta Headers Management

```ocaml
val required_betas :
  thinking:bool ->
  has_pdf:bool ->
  tool_streaming:bool ->
  string list
(** Returns beta header values needed for the request. *)

val merge_beta_headers :
  user_headers:(string * string) list ->
  required:string list ->
  (string * string) list
(** Merges required beta strings into the anthropic-beta header,
    deduplicating. *)
```

---

## 14. Package Structure

```
ai_provider_anthropic.opam
lib/ai_provider_anthropic/dune
```

Dependencies:
- `ai_provider` (the abstraction layer)
- `lwt`, `lwt.unix`
- `yojson`, `ppx_deriving_yojson`
- `cohttp-lwt-unix` (HTTP client)
- `devkit` (string utils, etc.)

---

## 15. Testing Strategy

### Unit Tests
- `Convert_prompt`: round-trip tests, message grouping edge cases
- `Convert_tools`: tool choice mapping
- `Convert_stream`: SSE parsing, stream transformation
- `Model_catalog`: capability lookups
- `Thinking`: smart constructor validation (budget < 1024 rejected)
- `Cache_control`: serialization

### Integration Tests (with mock server)
- Full `generate` flow with mock HTTP response
- Full `stream` flow with mock SSE stream
- Error handling (4xx, 5xx responses)
- Cancellation via abort signal

### Property-based tests
- Prompt conversion preserves message count
- SSE parser handles all valid SSE formats

---

## 16. Resolved Decisions

1. **HTTP library: `cohttp-lwt-unix`** — compatible with OCaml 4.14, integrates
   with Lwt, battle-tested. `piaf` requires OCaml >= 5.1 (Eio) — incompatible.
   Streaming uses `Lwt_stream.t` matching `claude-agent-sdk` patterns.

2. **Model catalog: variant + `Custom of string`** — current model list validated
   against Anthropic docs (March 2026). Current gen: Opus 4.6, Sonnet 4.6,
   Haiku 4.5. Legacy: Sonnet 4.5, Opus 4.5, Opus 4.1, Sonnet 4, Opus 4.
   `Custom of string` escape hatch for new/unknown models.

3. **Cache control: typed accessors with GADT key** — separate
   `Cache_control_options.Cache` GADT key for per-part cache control.
   Uses optional labeled argument `?cache_control` for ergonomic construction.
   See Section 4.4.

4. **Thinking + temperature: validate locally, emit `Warning.t`, send anyway** —
   the API may relax constraints in the future. Local validation provides
   immediate developer feedback; still sending the request avoids blocking
   on stale validation logic.

5. **Structured output: `Auto` mode** — checks model capabilities via
   `Model_catalog` to decide between `output_format` (newer models) and
   `json_tool` (older models). Requires keeping the catalog up-to-date, which
   is acceptable since we already maintain it for thinking/vision/etc.
