# Melange Bindings DX — Lessons Learned

> Analysis from building the `ai-e2e` example app against `ai_sdk_react` bindings.
> Identifies DX friction points and concrete improvements.

## 1. Accessor Verbosity — Module-Scoped Records Over Prefixed Functions

**Problem:** Every UI part type exposes free-standing functions with the type name
baked into each accessor: `tool_ui_part_state`, `tool_ui_part_tool_name`,
`tool_ui_part_input`, `source_url_ui_part_url`, etc. This is Java-style naming
that doesn't fit OCaml idioms and makes call sites noisy:

```ocaml
(* Current — 5 calls to read one tool part *)
let state = tool_ui_part_state p in
let name = match tool_ui_part_tool_name p with Some n -> n | None -> "tool" in
let input = tool_ui_part_input p in
```

**Solution:** Scope accessors under modules matching the type name.
`Tool_part.state p` instead of `tool_ui_part_state p`. Even better: provide
a `view` function that returns a record for destructuring:

```ocaml
(* Module-scoped accessors *)
let state = Tool_part.state p in
let name = Option.value ~default:"tool" (Tool_part.tool_name p) in

(* Or record view *)
let { Tool_part.state; tool_name; input; _ } = Tool_part.view p in
```

The external FFI declarations stay the same — just wrap them in a module.

## 2. `classify` Should Use Pattern Matching, Not `else if`

The `classify` function in `types.ml` uses an `else if` chain on string
comparisons. This violates the project's "else if is banned" rule and is less
readable than a `match`:

```ocaml
(* Fix: match directly on the type string *)
let classify part =
  match part_type part with
  | "text" -> Text (as_text part)
  | "reasoning" -> Reasoning (as_reasoning part)
  | "dynamic-tool" -> Tool_call (as_tool_call part)
  | t when String.length t > 5 && String.sub t 0 5 = "tool-" ->
    Tool_call (as_tool_call part)
  | "source-url" -> Source_url (as_source_url part)
  | ...
```

## 3. Callback Types Should Match JS Flexibility

The JS SDK's `onToolCall` accepts `void | PromiseLike<void>`. Binding this as
`Js.Json.t -> unit Js.Promise.t` forces every caller to return a promise.
Better: keep the default as `unit` (fire-and-forget), and add a separate
`on_tool_call_async` for callers that need promise-based flow. Or use a union
type if Melange supports it.

## 4. No Manual JSON Parsing in Examples

Two violations found:
- **Frontend** (`chat_message.mlx`): `try_render_structured` uses raw
  `Js.Json.decodeObject` / `Js.Dict.get` chains to parse structured output.
- **Backend** (`server/main.ml`): `handle_completion` uses raw
  `Yojson.Basic.from_string` + `List.assoc_opt` to parse `{ prompt: string }`.

Both should use typed records with derivers (`[@@deriving of_json]`).
The project's feedback memory is explicit: "Always use typed records with
derivers, never construct/parse JSON manually."

## 5. MLX Dialect Limitations to Document

Two pain points discovered during development:

- **`[@react.component]` with labeled args**: reason-react-ppx 0.15.0 does not
  generate `makeProps` for MLX files, so components with props cannot use JSX
  syntax. Workaround: use plain `render` functions instead of components.
- **`[@react.component]` as first item**: mlx-pp requires at least one structure
  item before `[@react.component]`. Workaround: add a dummy `let _x = ()` or
  a meaningful binding before the attribute.

## 6. `include Types` Flattens the Namespace

`ai_sdk_react.ml` does `include Types`, which dumps all accessor functions into
the top-level `Ai_sdk_react` namespace. After `open Ai_sdk_react`, you get
`text_ui_part_text`, `tool_ui_part_state`, etc. — all competing for namespace
space. If accessors were scoped under modules (`Text_part`, `Tool_part`, etc.),
this wouldn't be an issue.

## Action Items

1. Restructure `types.ml` to scope part accessors under modules
2. Fix `classify` to use pattern matching
3. Revert `on_tool_call` to `unit` return, add `on_tool_call_async` variant
4. Replace manual JSON parsing in examples with derivers
5. Document MLX dialect limitations in the bindings design doc
