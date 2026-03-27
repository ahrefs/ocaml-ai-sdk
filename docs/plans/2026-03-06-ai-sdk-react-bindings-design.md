# Melange Bindings for @ai-sdk/react

> Architectural reference for the Melange bindings (`bindings/ai-sdk-react/`).
> Targets `@ai-sdk/react` v3.x with `useChat` and `useCompletion` hooks.

## Design Decisions

1. **Abstract types with accessors** — JS objects (`UIMessage`, hook return values) are modeled as abstract `type t` with `mel.get`/`mel.send` accessors. This provides type safety without requiring record type declarations that could drift from the JS API.

2. **`mel.obj` for options** — All option constructor functions use `mel.obj` with optional labeled arguments, ensuring omitted fields are not emitted in JS output (preserving SDK defaults).

3. **Concrete opaque types for `mel.obj` returns** — Instead of `< .. > Js.t` (which doesn't work in `.mli` files), we use opaque types like `options`, `text_message`, `tool_output`.

4. **`classify` for discriminated unions** — `UIMessagePart` is a JS discriminated union. We provide `classify` which pattern-matches on the `type` field and returns a typed polymorphic variant.

5. **Default `UIMessage` only** — The generic `UI_MESSAGE` type parameter is not expressible in OCaml's type system. We bind to the default specialization which covers 95%+ of use cases.

6. **`DefaultChatTransport` included** — Bundled as a submodule of `Use_chat` since it's the primary way to configure the chat transport.

## Future Work

- **`useObject` hook** — Experimental (`experimental_useObject`). Schema-generic typing is complex in OCaml. Add when the API stabilizes.
- **Promise-returning variants** — `sendMessage`, `regenerate`, `stop`, `complete` return `Promise<void>` in TS but are bound as `unit`. Add `*_promise` variants for callers that need to await/chain.
- **`UseChatOptions` remaining fields** — `generateId`, `messageMetadataSchema`, `dataPartSchemas`, `sendAutomaticallyWhen`, and the `chat` pre-existing instance variant.
- **`tool_ui_part.approval`** — The approval object (`{ id, approved, reason }`) on approval-related tool states.
- **Generic `UI_MESSAGE` support** — Supporting custom metadata/data part types would require functorized bindings.
