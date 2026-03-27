# Provider Abstraction Design

> Architectural reference for the provider abstraction layer (`ai_provider`).
> Inspired by Vercel AI SDK's V3 specification.

## Goal

A provider-agnostic abstraction for language models. The Core SDK consumes
`Language_model.t` values without knowing which provider is behind them.

---

## Design Rationale

### Prompt Messages — Role-Constrained Variants

The variant type encodes valid content per role at **compile time**:

- **System**: text only — impossible to construct with an image
- **User**: text and files, but NOT tool calls or reasoning
- **Assistant**: text, files, reasoning, AND tool calls
- **Tool**: tool results only

This mirrors Vercel's V3 spec but enforces it statically rather than at runtime.

### Provider Options — Extensible GADT

```ocaml
type _ key = ..  (* extensible *)
type entry = Entry : 'a key * 'a -> entry
type t = entry list
```

Each provider extends the GADT in its own package:

```ocaml
(* In ai_provider_anthropic: *)
type _ Provider_options.key +=
  | Anthropic : Anthropic_options.t Provider_options.key
```

**Why this design (vs opaque JSON map):**
- **Type-safe construction:** impossible to pass a malformed option
- **Type-safe extraction:** pattern match on the GADT tag, get a typed value
- **No circular deps:** each provider extends `_ key` in its own package
- **Extensible:** adding a new provider is just `type _ key += MyProvider : ...`

**Cost:** consumers need to wrap/unwrap the existential — slightly more ceremony
than `.find "key"`, but catches provider option mismatches at compile time.

### Generation Mode

```ocaml
type t = Regular | Object_json of json_schema option | Object_tool of { tool_name; schema }
```

- **No `Object_grammar`:** rarely used, YAGNI. Can be added as a variant later.
- **`json_schema option` for `Object_json`:** `None` means "produce valid JSON, no schema constraint."

### Tool Choice

```ocaml
type t = Auto | Required | None_ | Specific of { tool_name : string }
```

`None_` with underscore — `None` is an OCaml keyword.

### Finish Reason — `Other of string`

Providers may introduce new finish reasons. Capturing the raw string lets
consumers handle unknowns explicitly instead of silently falling into a catch-all.

### Content — Tool call `args` as string

Tool call arguments arrive as JSON text. Keeping it as a string defers parsing
to the consumer layer (Core SDK), which knows the expected schema. Avoids double-parsing.

### `abort_signal` as `unit Lwt.t option`

Lwt-idiomatic cancellation. The caller creates a promise that resolves when they
want to cancel. The provider can `Lwt.pick` against it.

---

## Language Model Signature

The core abstraction — OCaml equivalent of `LanguageModelV3`:

```ocaml
module type S = sig
  val specification_version : string  (** "V3" *)
  val provider : string
  val model_id : string
  val generate : Call_options.t -> Generate_result.t Lwt.t
  val stream : Call_options.t -> Stream_result.t Lwt.t
end
```

**Why a module type (not a class or record of functions):**
1. Module types are OCaml's natural abstraction boundary; functors compose well
2. No mutable state leaks — configuration baked in at creation time
3. First-class modules allow runtime dispatch: `type t = (module S)`

---

## Provider Signature

```ocaml
module type S = sig
  val name : string
  val language_model : string -> (module Language_model.S)
end
```

**Why no dependency on HTTP:** Pure types and signatures only. Provider
implementations depend on this package, not the other way around.

---

## Middleware

```ocaml
module type S = sig
  val wrap_generate : generate:(Call_options.t -> Generate_result.t Lwt.t) -> Call_options.t -> Generate_result.t Lwt.t
  val wrap_stream : stream:(Call_options.t -> Stream_result.t Lwt.t) -> Call_options.t -> Stream_result.t Lwt.t
end

val apply : (module S) -> Language_model.t -> Language_model.t
```

Higher-order function wrapping — mirrors `LanguageModelV3Middleware`.
The OCaml version produces a new `Language_model.t` via `apply`.

---

## Resolved Decisions

1. **Streaming uses `Lwt_stream.t`** — matches `claude-agent-sdk` pattern.
   Revisitable later if backpressure becomes a concern.

2. **Image/Speech/Transcription models** — deferred (YAGNI). Architecture
   supports future additions: `Provider.S` gains optional methods, each model
   type gets its own signature, extensible GADT accommodates any model type.
   No existing code needs to change when these are added.
