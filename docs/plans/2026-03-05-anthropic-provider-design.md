# Anthropic Provider Design

> Architectural reference for the Anthropic provider (`ai_provider_anthropic`).

## Goal

Implement the Anthropic Messages API as a `Language_model.S` provider,
handling prompt conversion, streaming SSE, tool use, thinking, and cache control.

---

## Key Design Decisions

### Model Catalog — Variant + Custom Escape Hatch

```ocaml
type t = Opus_4_6 | Sonnet_4_6 | Haiku_4_5 | ... | Custom of string
```

The variant validates known models and their capabilities (thinking support,
vision, max tokens) at configuration time. `Custom of string` handles
new/unknown models without blocking adoption.

### Thinking Budget — Private Type with Smart Constructor

```ocaml
type budget_tokens = private int
val budget : int -> (budget_tokens, string) result
```

Anthropic requires >= 1024 tokens for thinking budget. A private type
makes it **impossible** to construct an invalid budget — the compiler
enforces the invariant, no runtime checks needed downstream.

### Cache Control — Separate GADT Key at Part Granularity

Cache control is per-content-part, while `Anthropic_options` is per-request.
Using a separate GADT key (`Cache_control_options.Cache`) keeps them
independent — you can set cache control on individual text/file parts
without touching request-level options.

```ocaml
type _ Provider_options.key += Cache : Cache_control.t Provider_options.key
```

**Why a variant for breakpoint type:** The TypeScript SDK uses `"ephemeral"`
as a string. In OCaml we use `type breakpoint = Ephemeral` so the compiler
catches typos and we can extend later.

### Structured Output Mode — Auto Detection

```ocaml
type structured_output_mode = Auto | Output_format | Json_tool
```

`Auto` checks model capabilities via `Model_catalog` to choose between
native `output_format` (newer models) and synthetic JSON tool (older models).

### Thinking + Temperature — Warn Locally, Send Anyway

The API may relax constraints in the future. Local validation provides
immediate developer feedback via `Warning.t`; still sending the request
avoids blocking on stale validation logic.

---

## Conversion Patterns

### Prompt Conversion

Anthropic has two key constraints the converter handles transparently:

1. **Strictly alternating user/assistant messages.** The converter groups
   consecutive same-role messages and inserts empty messages where needed.

2. **System message as top-level parameter.** System messages are extracted
   from the message list and sent as the `system` parameter, not in messages.

These are provider-specific quirks — the abstraction layer allows any
message sequence; the Anthropic converter normalizes it.

### Tool Choice Mapping

| SDK | Anthropic | Notes |
|-----|-----------|-------|
| `Auto` | `auto` | |
| `Required` | `any` | Naming difference |
| `None_` | omit tools | Don't send tools at all |
| `Specific { name }` | `tool { name }` | |

---

## Resolved Decisions

1. **HTTP library: `cohttp-lwt-unix`** — compatible with OCaml 4.14, Lwt
   integration. `piaf` requires OCaml >= 5.1 (Eio).

2. **Streaming: `Lwt_stream.t`** — matches `claude-agent-sdk` patterns.

3. **Model catalog maintenance** — acceptable burden since we already
   track capabilities for thinking/vision/structured output.
