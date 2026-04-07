# ai-sdk-react

Melange bindings for [`@ai-sdk/react`](https://ai-sdk.dev/docs/ai-sdk-ui) v3.x — provides `useChat` and `useCompletion` hooks for OCaml/Reason/mlx frontends.

## Install

```
opam install ai-sdk-react
```

Requires `melange` >= 4.0.0 and `@ai-sdk/react` / `ai` as npm dependencies.

## Usage

```ocaml
open Ai_sdk_react

let chat =
  Use_chat.use_chat
    ~transport:Use_chat.Default_chat_transport.(make ~api:"/api/chat" () |> to_transport)
    ()

(* Send a message *)
let () = Use_chat.send_text chat "Hello!"

(* Read state *)
let msgs = Use_chat.messages chat
let status = Use_chat.status chat
```

## Modules

- **`Types`** — v6 message types: `ui_message`, `ui_message_part`, `chat_status`, with a `classify` function for part type dispatch
- **`Use_chat`** — `useChat` hook binding with message send/receive, tool approval, tool output, auto-submit, transport config
- **`Use_completion`** — `useCompletion` hook binding

## Compatibility

Designed to work with an `ocaml-ai-sdk` backend serving the UIMessage stream protocol (`x-vercel-ai-ui-message-stream: v1`). See the root [README](../../README.md) and the [`ai-e2e`](../../examples/ai-e2e/) / [`melange_chat`](../../examples/melange_chat/) examples for full-stack setups.
