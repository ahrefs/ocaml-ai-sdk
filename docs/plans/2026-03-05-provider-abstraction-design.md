# Provider Abstraction Layer Design

## Goal

Define the provider-agnostic types and module signatures that any AI provider (Anthropic,
OpenAI, etc.) must implement. This is the OCaml equivalent of Vercel AI SDK's
`@ai-sdk/provider` package with its `LanguageModelV3` specification.

The key design principle: **use OCaml's type system to make impossible states
unrepresentable** while providing an ergonomic API for library consumers.

---

## 1. Module Structure

```
lib/
  ai_provider/           -- the provider abstraction package
    ai_provider.ml       -- top-level module re-exports
    model_id.ml          -- abstract model identifier
    prompt.ml            -- prompt types (roles, content parts)
    tool.ml              -- tool definitions and tool choice
    mode.ml              -- generation modes (regular, json, etc.)
    call_options.ml      -- unified call options record
    content.ml           -- response content parts
    finish_reason.ml     -- finish reason variant
    usage.ml             -- token usage
    generate_result.ml   -- doGenerate result
    stream_part.ml       -- streaming event parts
    stream_result.ml     -- doStream result
    warning.ml           -- provider warnings
    language_model.ml    -- the core LanguageModelV3 signature
    provider.ml          -- the ProviderV3 factory signature
    provider_error.ml    -- error types
```

Each type lives in its own module following the `type t` pattern. This keeps
signatures focused and allows consumers to refer to e.g. `Finish_reason.t`,
`Usage.t` without ambiguity.

---

## 2. Core Types — Design Rationale

### 2.1 Prompt Messages (`Prompt`)

The Vercel SDK uses a discriminated union of message roles where each role
constrains which content parts are allowed. In TypeScript this is a tagged union.
In OCaml we can do **better** — the variant itself encodes valid content per role:

```ocaml
(** A single part in a user message. *)
type user_part =
  | Text of { text : string; provider_options : Provider_options.t }
  | File of { data : file_data; media_type : string; filename : string option;
              provider_options : Provider_options.t }

(** A single part in an assistant message. *)
type assistant_part =
  | Text of { text : string; provider_options : Provider_options.t }
  | File of { data : file_data; media_type : string; filename : string option;
              provider_options : Provider_options.t }
  | Reasoning of { text : string; provider_options : Provider_options.t }
  | Tool_call of { id : string; name : string; args : Yojson.Safe.t;
                   provider_options : Provider_options.t }

(** A tool result part. *)
type tool_result = {
  tool_call_id : string;
  tool_name : string;
  result : Yojson.Safe.t;
  is_error : bool;
  content : tool_result_content list;
  provider_options : Provider_options.t;
}

and tool_result_content =
  | Result_text of string
  | Result_image of { data : string; media_type : string }

(** A prompt message — the role constrains valid content parts. *)
type message =
  | System of { content : string }
  | User of { content : user_part list }
  | Assistant of { content : assistant_part list }
  | Tool of { content : tool_result list }
```

**Why this design:**
- **System** can only hold a string — not files, not tool calls. The type
  prevents constructing a system message with an image.
- **User** can hold text and files but NOT tool calls or reasoning.
- **Assistant** can hold text, files, reasoning, AND tool calls.
- **Tool** can only hold tool results.
- This mirrors Vercel's V3 spec but enforces it at **compile time**.

**`file_data`** is a variant to handle different input forms:

```ocaml
type file_data =
  | Bytes of bytes
  | Base64 of string
  | Url of string
```

This avoids the TypeScript `string | Uint8Array` ambiguity.

**`Provider_options.t`** uses an extensible GADT for compile-time type safety:

```ocaml
(** Provider-specific options that flow through without breaking compatibility.
    Uses an extensible GADT so each provider can register its own typed key
    without the abstraction layer knowing about all providers. *)
module Provider_options : sig
  (** Extensible GADT — each provider adds a constructor via [+=]. *)
  type _ key = ..

  (** Existential wrapper: a typed key paired with its value. *)
  type entry = Entry : 'a key * 'a -> entry

  (** A bag of provider-specific options. *)
  type t = entry list

  val empty : t

  (** Add or replace an option. *)
  val set : 'a key -> 'a -> t -> t

  (** Look up an option by key. Returns [None] if absent or wrong key. *)
  val find : 'a key -> t -> 'a option

  (** Find or raise — use when the option is mandatory. *)
  val find_exn : 'a key -> t -> 'a
end
```

Each provider extends the GADT in its own package:

```ocaml
(* In ai_provider_anthropic: *)
type _ Provider_options.key +=
  | Anthropic : Anthropic_options.t Provider_options.key

(* Usage — constructing options: *)
let opts = Provider_options.(set Anthropic { thinking = Some t; ... } empty)

(* Usage — extracting options in the provider implementation: *)
match Provider_options.find Anthropic opts with
| Some { thinking; cache_control; _ } -> (* use typed values *)
| None -> (* no Anthropic-specific options *)
```

**Why this design (vs opaque JSON map):**
- **Type-safe construction:** impossible to pass a malformed option — the compiler
  enforces the record structure.
- **Type-safe extraction:** pattern match on the GADT tag, get a typed value.
- **No circular deps:** each provider extends `_ key` in its own package.
- **Bounded complexity:** ~20 lines of boilerplate per provider. The rest of the
  codebase passes `Provider_options.t` around opaquely.
- **Extensible:** adding a new provider is just `type _ key += MyProvider : ...`.

**Cost:** consumers need to wrap/unwrap the existential — slightly more ceremony
than `.find "key"`, but the type safety is worth it for catching provider
option mismatches at compile time.

### 2.2 Generation Mode (`Mode`)

```ocaml
type json_schema = {
  name : string;
  schema : Yojson.Safe.t;
}

type t =
  | Regular
  | Object_json of json_schema option
  | Object_tool of { tool_name : string; schema : json_schema }
```

**Why no `Object_grammar`:** Grammar mode is rarely used, only supported by a
few providers, and adds complexity. We follow YAGNI. Can be added later as a
variant without breaking existing code.

**Why `json_schema option` for Object_json:** Some providers can infer schema,
others need it explicitly. `None` means "produce valid JSON, no schema constraint."

### 2.3 Tool Definition and Choice (`Tool`)

```ocaml
module Tool : sig
  type t = {
    name : string;
    description : string option;
    parameters : Yojson.Safe.t; (** JSON Schema *)
  }
end

module Tool_choice : sig
  type t =
    | Auto
    | Required
    | None_
    | Specific of { tool_name : string }
end
```

**Why `None_` with underscore:** `None` is already an OCaml keyword for options.
The underscore suffix is idiomatic for avoiding keyword clashes.

### 2.4 Finish Reason (`Finish_reason`)

```ocaml
type t =
  | Stop
  | Length
  | Tool_calls
  | Content_filter
  | Error
  | Other of string
  | Unknown

val to_string : t -> string
val of_string : string -> t
```

**Why `Other of string`:** Providers may introduce new finish reasons. Rather
than silently falling into a catch-all, we capture the raw string so consumers
can pattern match on known cases and handle unknowns explicitly.

### 2.5 Token Usage (`Usage`)

```ocaml
type t = {
  input_tokens : int;
  output_tokens : int;
  total_tokens : int option;
}
```

**Why `total_tokens` is optional:** Not all providers report it. Making it
optional avoids inventing a sum that may be inaccurate (some providers count
cached tokens differently).

### 2.6 Response Content (`Content`)

```ocaml
type t =
  | Text of { text : string }
  | Tool_call of {
      tool_call_type : string;  (** always "function" for now *)
      tool_call_id : string;
      tool_name : string;
      args : string;  (** raw JSON string — consumer decides when to parse *)
    }
  | Reasoning of {
      text : string;
      signature : string option;
      provider_options : Provider_options.t;
    }
  | File of {
      data : bytes;
      media_type : string;
    }
```

**Why `args` is a string:** Tool call arguments arrive as JSON text. Keeping it
as a string defers parsing to the consumer layer (the Core SDK), which knows the
expected schema. This avoids double-parsing.

### 2.7 Warnings (`Warning`)

```ocaml
type t =
  | Unsupported_feature of { feature : string; details : string option }
  | Other of { message : string }
```

### 2.8 Provider Error (`Provider_error`)

```ocaml
type error_kind =
  | Api_error of { status : int; body : string }
  | Network_error of { message : string }
  | Deserialization_error of { message : string; raw : string }

type t = {
  provider : string;
  kind : error_kind;
}

exception Provider_error of t
```

---

## 3. Call Options (`Call_options`)

The unified input to both `generate` and `stream`:

```ocaml
type t = {
  prompt : Prompt.message list;
  mode : Mode.t;
  tools : Tool.t list;
  tool_choice : Tool_choice.t option;
  max_output_tokens : int option;
  temperature : float option;
  top_p : float option;
  top_k : int option;
  stop_sequences : string list;
  seed : int option;
  frequency_penalty : float option;
  presence_penalty : float option;
  response_format : Mode.t option;
  provider_options : Provider_options.t;
  headers : (string * string) list;
  abort_signal : unit Lwt.t option;  (** resolves when caller wants to abort *)
}

val default : prompt:Prompt.message list -> t
(** Minimal call options — only prompt is required, everything else defaults. *)
```

**Why `abort_signal` as `unit Lwt.t option`:** This is the Lwt-idiomatic way to
express cancellation. The caller creates a promise that resolves when they want
to cancel. The provider implementation can `Lwt.pick` against it.

---

## 4. Generate Result (`Generate_result`)

```ocaml
type t = {
  content : Content.t list;
  finish_reason : Finish_reason.t;
  usage : Usage.t;
  warnings : Warning.t list;
  provider_metadata : Provider_options.t;
  request : request_info;
  response : response_info;
}

and request_info = { body : Yojson.Safe.t }
and response_info = {
  id : string option;
  model : string option;
  headers : (string * string) list;
  body : Yojson.Safe.t;
}
```

---

## 5. Stream Result (`Stream_result`)

### 5.1 Stream Parts

```ocaml
type t =
  | Stream_start of { warnings : Warning.t list }
  | Text of { text : string }
  | Reasoning of { text : string }
  | Tool_call_delta of {
      tool_call_type : string;
      tool_call_id : string;
      tool_name : string;
      args_text_delta : string;
    }
  | Tool_call_finish of { tool_call_id : string }
  | File of { data : bytes; media_type : string }
  | Finish of { finish_reason : Finish_reason.t; usage : Usage.t }
  | Error of { error : Provider_error.t }
  | Provider_metadata of { metadata : Provider_options.t }
```

### 5.2 Stream Result

```ocaml
type t = {
  stream : Stream_part.t Lwt_stream.t;
  warnings : Warning.t list;
  raw_response : response_info option;
}
```

**Why `Lwt_stream.t`:** Matches the pattern used in `claude-agent-sdk` (which
uses `Lwt_stream.t` for subprocess output). Integrates naturally with Lwt
cancellation via `Lwt_switch`. Revisitable later if backpressure becomes a
concern, but sufficient for SSE consumption.

---

## 6. The Language Model Signature (`Language_model`)

This is the core abstraction — the OCaml equivalent of `LanguageModelV3`:

```ocaml
module type S = sig
  (** Specification version for compatibility checking. *)
  val specification_version : string  (** "V3" *)

  (** Provider identifier, e.g. "anthropic", "openai". *)
  val provider : string

  (** Model identifier, e.g. "claude-sonnet-4-20250514". *)
  val model_id : string

  (** Non-streaming generation. *)
  val generate : Call_options.t -> Generate_result.t Lwt.t

  (** Streaming generation. *)
  val stream : Call_options.t -> Stream_result.t Lwt.t
end
```

**Why a module type (not a class or record of functions):**

1. **Module types are OCaml's natural abstraction boundary.** Functors can accept
   them, and they compose well.
2. **No mutable state leaks.** Each provider implementation is a module — the
   configuration is baked in at creation time via a functor or `create` function.
3. **First-class modules** allow runtime dispatch when needed:
   ```ocaml
   type language_model = (module Language_model.S)
   ```

We also provide a **first-class module wrapper** for ergonomic runtime use:

```ocaml
type t = (module S)

val generate : t -> Call_options.t -> Generate_result.t Lwt.t
val stream : t -> Call_options.t -> Stream_result.t Lwt.t
val provider : t -> string
val model_id : t -> string
```

---

## 7. The Provider Signature (`Provider`)

The factory that creates model instances:

```ocaml
module type S = sig
  (** Provider name. *)
  val name : string

  (** Create a language model for the given model ID. *)
  val language_model : string -> (module Language_model.S)

  (** Create an embedding model for the given model ID.
      Returns None if the provider doesn't support embeddings. *)
  val embedding_model : string -> (module Embedding_model.S) option
end
```

**Why `option` for embedding_model:** Not all providers support all model types.
Returning `option` is more honest than raising. The consumer can pattern-match
and get a compile-time reminder to handle the missing case.

Runtime wrapper:

```ocaml
type t = (module S)

val language_model : t -> string -> Language_model.t
val name : t -> string
```

---

## 8. Middleware (`Middleware`)

For cross-cutting concerns (logging, caching, retries):

```ocaml
module type S = sig
  val wrap_generate :
    generate:(Call_options.t -> Generate_result.t Lwt.t) ->
    Call_options.t -> Generate_result.t Lwt.t

  val wrap_stream :
    stream:(Call_options.t -> Stream_result.t Lwt.t) ->
    Call_options.t -> Stream_result.t Lwt.t
end

val apply_middleware :
  (module S) -> Language_model.t -> Language_model.t
```

**Why this signature:** It mirrors Vercel's `LanguageModelV3Middleware` exactly —
a higher-order function that wraps the generate/stream functions. The OCaml
version is cleaner because the middleware is a module that gets applied via
`apply_middleware`, producing a new `Language_model.t`.

---

## 9. Package Structure

```
ai_provider.opam           -- package metadata
lib/ai_provider/dune        -- (library (name ai_provider) ...)
```

Dependencies: `lwt`, `yojson`, `ppx_deriving_yojson`

No dependency on any specific provider or HTTP library — this is pure types and
signatures. Provider implementations depend on this package, not the other way
around.

---

## 10. Integration Points with Core SDK (Future)

The Core SDK (future work) will consume `Language_model.t` values:

```ocaml
(* Future core SDK usage *)
val generate_text :
  model:Language_model.t ->
  prompt:string ->
  Generate_result.t Lwt.t

val stream_text :
  model:Language_model.t ->
  prompt:string ->
  Stream_result.t Lwt.t
```

The abstraction layer is designed so the Core SDK never needs to know which
provider is behind the `Language_model.t` value. This is the entire point.

---

## 11. Resolved Decisions

1. **`Provider_options.t` uses extensible GADT** — type-safe at compile time.
   Each provider extends `type _ key += ...` in its own package. ~20 lines of
   boilerplate per provider; the rest of the codebase is opaque. See Section 2.1
   for the full design.

2. **Image/Transcription/Speech models** — deferred (YAGNI). The architecture
   supports future additions without breaking changes:
   - `Provider.S` can gain `image_model`, `speech_model`, etc. as optional
     methods (returning `option`).
   - Each new model type gets its own module signature (e.g. `Image_model.S`).
   - The extensible GADT for provider options accommodates any model type.
   - No existing code needs to change when these are added.

3. **Streaming uses `Lwt_stream.t`** — matches `claude-agent-sdk` pattern.
   Revisitable later if backpressure becomes a concern.
