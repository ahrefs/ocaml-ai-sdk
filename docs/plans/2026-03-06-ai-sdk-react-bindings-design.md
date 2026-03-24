# Melange Bindings for @ai-sdk/react

**Date:** 2026-03-06
**Package version:** @ai-sdk/react v3.0.118
**Location:** `bindings/ai-sdk-react/`

## Scope

Melange bindings for two stable React hooks from Vercel's AI SDK:
- `useChat` — conversational chat UI with streaming
- `useCompletion` — text completion streaming

`useObject` (experimental) excluded from initial scope.

## Architecture

```
bindings/ai-sdk-react/
  dune                    # melange library config
  ai_sdk_react.ml[i]     # Main module re-exporting submodules
  types.ml[i]             # Shared types (UIMessage, ChatStatus, parts)
  use_chat.ml[i]          # useChat hook bindings
  use_completion.ml[i]    # useCompletion hook bindings
```

## Design Decisions

1. **Abstract types with accessors** — JS objects (`UIMessage`, hook return values) are modeled as abstract `type t` with `mel.get`/`mel.send` accessors. This provides type safety without requiring record type declarations that could drift from the JS API.

2. **`mel.obj` for options** — All option constructor functions use `mel.obj` with optional labeled arguments, ensuring omitted fields are not emitted in JS output (preserving SDK defaults).

3. **Concrete opaque types for `mel.obj` returns** — Instead of `< .. > Js.t` (which doesn't work in `.mli` files), we use opaque types like `options`, `text_message`, `tool_output`.

4. **`classify` for discriminated unions** — `UIMessagePart` is a JS discriminated union. We provide `classify` which pattern-matches on the `type` field and returns a typed polymorphic variant.

5. **Default `UIMessage` only** — The generic `UI_MESSAGE` type parameter is not expressible in OCaml's type system. We bind to the default specialization which covers 95%+ of use cases.

6. **`DefaultChatTransport` included** — Bundled as a submodule of `Use_chat` since it's the primary way to configure the chat transport.

## Dependencies

- `melange` (>= 4.0.0)
- `melange.dom` (for `Dom.event`)
- `melange.ppx` (preprocessor)

## npm peer dependencies

- `@ai-sdk/react` ^3.0.118
- `ai` (for `DefaultChatTransport`)
- `react` ^18 || ^19

## Future Work

The following items were identified during code review but deferred:

- **`useObject` hook** — Experimental (`experimental_useObject`). Schema-generic typing is complex in OCaml. Add when the API stabilizes.
- **Promise-returning variants** — `sendMessage`, `regenerate`, `stop`, `complete` etc. return `Promise<void>` in TS but are bound as `unit`. Add `*_promise` variants returning `Js.Promise.t` for callers that need to await/chain.
- **`UseCompletionOptions.fetch`** — Custom fetch implementation. Requires complex `Js.t` function type for marginal benefit.
- **`UseChatOptions` remaining fields** — `generateId`, `messageMetadataSchema`, `dataPartSchemas`, `sendAutomaticallyWhen`, and the `chat` (pre-existing Chat instance) variant are not yet bound.
- **`tool_ui_part.approval`** — The approval object (`{ id, approved, reason }`) on approval-related tool states is not bound.
- **Generic `UI_MESSAGE` support** — The bindings use the default `UIMessage` specialization. Supporting custom metadata/data part types would require functorized bindings.
