# Provider Abstraction + Anthropic Provider Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the provider abstraction layer (`ai_provider`) and the Anthropic provider (`ai_provider_anthropic`) for the OCaml AI SDK, enabling type-safe, provider-agnostic AI model usage.

**Architecture:** Two libraries — `ai_provider` defines provider-agnostic types and module signatures (extensible GADT for provider options, role-constrained prompt messages, Language_model.S module type). `ai_provider_anthropic` implements those signatures against the Anthropic Messages API using cohttp-lwt-unix for HTTP and Lwt_stream for SSE streaming. See `docs/plans/2026-03-05-provider-abstraction-design.md` and `docs/plans/2026-03-05-anthropic-provider-design.md` for full design rationale.

**Tech Stack:**
- OCaml 4.14.0
- lwt 5.9.2, lwt_ppx 5.9.1
- cohttp-lwt-unix 5.3.0
- yojson 2.2.2, ppx_deriving_yojson 3.9.1, ppx_deriving 6.0.3
- alcotest 1.9.1 (testing)
- ounit2 2.2.7 (testing, used by devkit)
- devkit 1.20240429 (string utils)
- trace 0.12 (logging)
- ocamlformat 0.28.1

**Formatting config:** Copy `claude-agent-sdk/.ocamlformat` to project root. All code must be formatted with `ocamlformat` after each task.

**Testing pattern:** Alcotest (see `claude-agent-sdk/test/test_parse.ml` for style reference). Tests go in `test/` directories with `(test ...)` dune stanzas.

**Design documents:**
- `docs/plans/2026-03-05-provider-abstraction-design.md` — the full abstraction layer spec
- `docs/plans/2026-03-05-anthropic-provider-design.md` — the full Anthropic provider spec

---

## Quality Gates (apply to EVERY task)

Every task must pass these gates before committing:

1. **Pre-implementation: Context7 verification** — Before writing code that uses any external library API (lwt, cohttp, yojson, etc.), verify the API signatures against context7 docs for the exact versions listed above. Do NOT guess API signatures.

2. **Post-implementation: Format** — Run `ocamlformat -i <files>` on all modified `.ml` and `.mli` files.

3. **Post-implementation: Build** — Run `dune build` from project root. Must succeed with zero errors.

4. **Post-implementation: Test** — Run `dune runtest` from project root. All tests must pass.

5. **Post-implementation: Subagent review** — Spawn a review subagent that checks:
   - Code follows the design documents (sections referenced in each task)
   - Types match the plan's OCaml signatures
   - No `open!` or top-level `include`
   - No polymorphic compare (`=` on non-primitive types)
   - No `List.hd`, `List.tl`, `Option.get`, `Obj.magic`, `Str.*`
   - No catch-all patterns on non-boolean types
   - Labeled arguments used for functions with >2 params
   - `.mli` files exist for all public modules

---

## Group 0: Project Setup

### Task 0.1: Install dependencies

**Files:**
- Modify: `dune-project`
- Modify: `ocaml-ai-sdk.opam`

**Step 1: Install dependencies into the local opam switch**

```bash
opam install lwt.5.9.2 lwt_ppx.5.9.1 cohttp-lwt-unix.5.3.0 yojson.2.2.2 \
  ppx_deriving_yojson.3.9.1 ppx_deriving.6.0.3 ounit2.2.2.7 alcotest.1.9.1 \
  devkit.1.20240429 trace.0.12 -y
```

Expected: All packages install successfully.

**Step 2: Update `dune-project` package metadata**

Update the `ocaml-ai-sdk` package `depends` in `dune-project` to list runtime deps:

```lisp
(package
 (name ocaml-ai-sdk)
 (synopsis "OCaml AI SDK - Provider abstraction for AI models")
 (description "Type-safe, provider-agnostic AI model abstraction inspired by Vercel AI SDK")
 (depends
  (ocaml (>= 4.14))
  (lwt (>= 5.9))
  (yojson (>= 2.2))
  (ppx_deriving_yojson (>= 3.9))
  (cohttp-lwt-unix (>= 5.3))
  (devkit (>= 1.20240429))
  (alcotest :with-test)))
```

**Step 3: Copy `.ocamlformat` to project root**

Copy `claude-agent-sdk/.ocamlformat` to the project root so all code in the repo uses the same formatting rules.

**Step 4: Verify build still works**

```bash
dune build
```

Expected: Builds with no errors (existing `claude-agent-sdk` and empty `lib/` still compile).

**Step 5: Commit**

```bash
git add dune-project .ocamlformat ocaml-ai-sdk.opam
git commit -m "chore: add dependencies for provider abstraction and Anthropic provider"
```

---

## Group 1: Provider Abstraction Layer — Foundation Types

These are the leaf types with no internal dependencies. All live in `lib/ai_provider/`.

### Task 1.1: Provider_options (extensible GADT)

**Design ref:** `provider-abstraction-design.md` Section 2.1 (Provider_options)

**Files:**
- Create: `lib/ai_provider/provider_options.ml`
- Create: `lib/ai_provider/provider_options.mli`
- Create: `lib/ai_provider/dune`
- Create: `test/ai_provider/test_provider_options.ml`
- Create: `test/ai_provider/dune`

**Step 1: Create the dune build file for ai_provider**

```lisp
(library
 (name ai_provider)
 (public_name ocaml-ai-sdk.ai_provider)
 (libraries lwt yojson)
 (preprocess
  (pps ppx_deriving_yojson ppx_deriving.show)))
```

**Step 2: Create the test dune file**

```lisp
(test
 (name test_provider_options)
 (libraries ai_provider alcotest)
 (preprocess
  (pps ppx_deriving_yojson)))
```

**Step 3: Write the failing test**

```ocaml
(* test/ai_provider/test_provider_options.ml *)

(* Define a test GADT key *)
type _ Ai_provider.Provider_options.key += Test_key : string Ai_provider.Provider_options.key

let test_empty () =
  let opts = Ai_provider.Provider_options.empty in
  Alcotest.(check (option string)) "empty has no value" None
    (Ai_provider.Provider_options.find Test_key opts)

let test_set_and_find () =
  let opts =
    Ai_provider.Provider_options.empty
    |> Ai_provider.Provider_options.set Test_key "hello"
  in
  Alcotest.(check (option string)) "finds value" (Some "hello")
    (Ai_provider.Provider_options.find Test_key opts)

(* Define a second key to test isolation *)
type _ Ai_provider.Provider_options.key += Other_key : int Ai_provider.Provider_options.key

let test_different_keys () =
  let opts =
    Ai_provider.Provider_options.empty
    |> Ai_provider.Provider_options.set Test_key "hello"
  in
  Alcotest.(check (option int)) "other key not found" None
    (Ai_provider.Provider_options.find Other_key opts)

let test_set_replaces () =
  let opts =
    Ai_provider.Provider_options.empty
    |> Ai_provider.Provider_options.set Test_key "first"
    |> Ai_provider.Provider_options.set Test_key "second"
  in
  Alcotest.(check (option string)) "replaced" (Some "second")
    (Ai_provider.Provider_options.find Test_key opts)

let () =
  Alcotest.run "Provider_options"
    [
      ( "basics",
        [
          Alcotest.test_case "empty" `Quick test_empty;
          Alcotest.test_case "set_and_find" `Quick test_set_and_find;
          Alcotest.test_case "different_keys" `Quick test_different_keys;
          Alcotest.test_case "set_replaces" `Quick test_set_replaces;
        ] );
    ]
```

**Step 4: Run test to verify it fails**

```bash
dune runtest
```

Expected: FAIL — `Ai_provider.Provider_options` does not exist yet.

**Step 5: Implement Provider_options**

`lib/ai_provider/provider_options.mli`:
```ocaml
(** Provider-specific options using an extensible GADT.
    Each provider registers its own typed key without circular dependencies. *)

(** Extensible GADT — each provider adds a constructor via [+=]. *)
type _ key = ..

(** Existential wrapper: a typed key paired with its value. *)
type entry = Entry : 'a key * 'a -> entry

(** A bag of provider-specific options. *)
type t = entry list

val empty : t

(** Add or replace an option keyed by the GADT constructor. *)
val set : 'a key -> 'a -> t -> t

(** Look up an option by key. Returns [None] if absent. *)
val find : 'a key -> t -> 'a option

(** Look up an option by key. Raises [Not_found] if absent. *)
val find_exn : 'a key -> t -> 'a
```

`lib/ai_provider/provider_options.ml`:
```ocaml
type _ key = ..

type entry = Entry : 'a key * 'a -> entry

type t = entry list

let empty = []

let set (type a) (k : a key) (v : a) (opts : t) : t =
  let replaced = ref false in
  let opts' =
    List.filter_map
      (fun (Entry (k', _) as e) ->
        match (k, k') with
        | k, k' when Obj.Extension_constructor.id (Obj.Extension_constructor.of_val k)
                    = Obj.Extension_constructor.id (Obj.Extension_constructor.of_val k') ->
          replaced := true;
          Some (Entry (k, v))
        | _ -> Some e)
      opts
  in
  if !replaced then opts' else Entry (k, v) :: opts

let find (type a) (k : a key) (opts : t) : a option =
  let kid = Obj.Extension_constructor.id (Obj.Extension_constructor.of_val k) in
  let rec go = function
    | [] -> None
    | Entry (k', v) :: rest ->
      if Obj.Extension_constructor.id (Obj.Extension_constructor.of_val k') = kid then
        (* The GADT guarantees type equality when constructor ids match *)
        Some (Obj.magic v : a)
      else go rest
  in
  go opts

let find_exn k opts =
  match find k opts with
  | Some v -> v
  | None -> raise Not_found
```

> **NOTE on `Obj.magic`:** This is the standard pattern for extensible GADT
> existentials in OCaml. The `Obj.Extension_constructor.id` comparison
> guarantees the types match — the `Obj.magic` is type-safe here. This is
> the same approach used by `Printexc`, `Format`, and other stdlib modules.
> There is no way to avoid it with extensible variants (unlike closed GADTs
> where the compiler can witness the equality). Document this clearly in the
> `.ml` file.

**Step 6: Create the top-level module**

`lib/ai_provider/ai_provider.ml`:
```ocaml
module Provider_options = Provider_options
```

**Step 7: Run tests**

```bash
dune runtest
```

Expected: All 4 tests pass.

**Step 8: Format and commit**

```bash
ocamlformat -i lib/ai_provider/provider_options.ml lib/ai_provider/provider_options.mli lib/ai_provider/ai_provider.ml test/ai_provider/test_provider_options.ml
dune build
git add lib/ai_provider/ test/ai_provider/
git commit -m "feat(ai_provider): add Provider_options extensible GADT"
```

---

### Task 1.2: Finish_reason, Usage, Warning, Provider_error

**Design ref:** `provider-abstraction-design.md` Sections 2.4, 2.5, 2.7, 2.8

**Files:**
- Create: `lib/ai_provider/finish_reason.ml`
- Create: `lib/ai_provider/finish_reason.mli`
- Create: `lib/ai_provider/usage.ml`
- Create: `lib/ai_provider/usage.mli`
- Create: `lib/ai_provider/warning.ml`
- Create: `lib/ai_provider/warning.mli`
- Create: `lib/ai_provider/provider_error.ml`
- Create: `lib/ai_provider/provider_error.mli`
- Modify: `lib/ai_provider/ai_provider.ml` (re-export)
- Create: `test/ai_provider/test_foundation_types.ml`
- Modify: `test/ai_provider/dune` (add test)

**Step 1: Write tests for all four modules**

Test file: `test/ai_provider/test_foundation_types.ml`

Test cases:
- `Finish_reason.of_string` / `to_string` round-trips for all known variants
- `Finish_reason.of_string "unknown_thing"` returns `Other "unknown_thing"`
- `Usage.t` construction
- `Warning.t` variant construction
- `Provider_error.t` construction and exception raising

**Step 2: Run tests — expect failure**

**Step 3: Implement all four modules**

Each module: `.ml` + `.mli` following the types in the design doc.

Key implementation notes:
- `Finish_reason.of_string`: pattern match on lowercase strings, fallback to `Other s`
- `Usage.t`: simple record with `input_tokens`, `output_tokens`, `total_tokens` option
- `Warning.t`: `Unsupported_feature` and `Other` variants
- `Provider_error.t`: record with `provider` string and `error_kind` variant; declare `exception Provider_error of t`

**Step 4: Re-export from ai_provider.ml**

```ocaml
module Provider_options = Provider_options
module Finish_reason = Finish_reason
module Usage = Usage
module Warning = Warning
module Provider_error = Provider_error
```

**Step 5: Update test dune to add the new test**

Add a second `(test ...)` stanza or combine into a single test runner.

**Step 6: Run tests, format, build, commit**

```bash
dune runtest
ocamlformat -i lib/ai_provider/*.ml lib/ai_provider/*.mli test/ai_provider/*.ml
dune build
git add lib/ai_provider/ test/ai_provider/
git commit -m "feat(ai_provider): add Finish_reason, Usage, Warning, Provider_error"
```

---

### Task 1.3: Prompt types (file_data, content parts, messages)

**Design ref:** `provider-abstraction-design.md` Section 2.1

**Files:**
- Create: `lib/ai_provider/prompt.ml`
- Create: `lib/ai_provider/prompt.mli`
- Create: `test/ai_provider/test_prompt.ml`
- Modify: `test/ai_provider/dune`
- Modify: `lib/ai_provider/ai_provider.ml`

**Step 1: Write tests**

Test cases:
- Construct each message variant: `System`, `User`, `Assistant`, `Tool`
- Construct each content part variant for each role
- Verify `file_data` variants (`Bytes`, `Base64`, `Url`)
- Verify `tool_result_content` variants
- **Compile-time safety**: these tests mainly verify construction compiles —
  the type system does the heavy lifting. Add a few structural assertions.

**Step 2: Implement Prompt module**

Types:
```ocaml
type file_data = Bytes of bytes | Base64 of string | Url of string

type user_part =
  | Text of { text : string; provider_options : Provider_options.t }
  | File of {
      data : file_data;
      media_type : string;
      filename : string option;
      provider_options : Provider_options.t;
    }

type assistant_part =
  | Text of { text : string; provider_options : Provider_options.t }
  | File of {
      data : file_data;
      media_type : string;
      filename : string option;
      provider_options : Provider_options.t;
    }
  | Reasoning of { text : string; provider_options : Provider_options.t }
  | Tool_call of {
      id : string;
      name : string;
      args : Yojson.Safe.t;
      provider_options : Provider_options.t;
    }

type tool_result_content = Result_text of string | Result_image of { data : string; media_type : string }

type tool_result = {
  tool_call_id : string;
  tool_name : string;
  result : Yojson.Safe.t;
  is_error : bool;
  content : tool_result_content list;
  provider_options : Provider_options.t;
}

type message =
  | System of { content : string }
  | User of { content : user_part list }
  | Assistant of { content : assistant_part list }
  | Tool of { content : tool_result list }
```

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider): add Prompt types with role-constrained content"
```

---

### Task 1.4: Tool, Mode, Content types

**Design ref:** `provider-abstraction-design.md` Sections 2.2, 2.3, 2.6

**Files:**
- Create: `lib/ai_provider/tool.ml` + `.mli`
- Create: `lib/ai_provider/tool_choice.ml` + `.mli`
- Create: `lib/ai_provider/mode.ml` + `.mli`
- Create: `lib/ai_provider/content.ml` + `.mli`
- Create: `test/ai_provider/test_tool_mode_content.ml`
- Modify: `test/ai_provider/dune`
- Modify: `lib/ai_provider/ai_provider.ml`

**Step 1: Write tests**

Test cases:
- `Tool.t` construction
- `Tool_choice.t` all variants
- `Mode.t` all variants including `Object_json None` and `Object_json (Some schema)`
- `Content.t` all variants

**Step 2: Implement — straightforward record/variant types per design doc**

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider): add Tool, Tool_choice, Mode, Content types"
```

---

### Task 1.5: Call_options, Generate_result, Stream_part, Stream_result

**Design ref:** `provider-abstraction-design.md` Sections 3, 4, 5

**Files:**
- Create: `lib/ai_provider/call_options.ml` + `.mli`
- Create: `lib/ai_provider/generate_result.ml` + `.mli`
- Create: `lib/ai_provider/stream_part.ml` + `.mli`
- Create: `lib/ai_provider/stream_result.ml` + `.mli`
- Create: `test/ai_provider/test_call_options.ml`
- Modify: `test/ai_provider/dune`
- Modify: `lib/ai_provider/ai_provider.ml`

**Step 1: Write tests**

Test cases:
- `Call_options.default` creates valid defaults (empty tools, no temperature, etc.)
- `Generate_result.t` construction
- `Stream_part.t` all variants
- `Stream_result.t` construction with a mock `Lwt_stream.t`

**Step 2: Implement**

Key: `Call_options.default` function:
```ocaml
val default : prompt:Prompt.message list -> t
```

Must set sensible defaults: `mode = Regular`, `tools = []`, `tool_choice = None`,
all optional params to `None`, `stop_sequences = []`, `headers = []`,
`provider_options = Provider_options.empty`, `abort_signal = None`.

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider): add Call_options, Generate_result, Stream_part, Stream_result"
```

---

### Task 1.6: Language_model and Provider signatures

**Design ref:** `provider-abstraction-design.md` Sections 6, 7, 8

**Files:**
- Create: `lib/ai_provider/language_model.ml` + `.mli`
- Create: `lib/ai_provider/provider.ml` + `.mli`
- Create: `lib/ai_provider/middleware.ml` + `.mli`
- Modify: `lib/ai_provider/ai_provider.ml`

**Step 1: Implement Language_model**

```ocaml
(* language_model.mli *)
module type S = sig
  val specification_version : string
  val provider : string
  val model_id : string
  val generate : Call_options.t -> Generate_result.t Lwt.t
  val stream : Call_options.t -> Stream_result.t Lwt.t
end

type t = (module S)

val generate : t -> Call_options.t -> Generate_result.t Lwt.t
val stream : t -> Call_options.t -> Stream_result.t Lwt.t
val provider : t -> string
val model_id : t -> string
```

**Step 2: Implement Provider**

```ocaml
(* provider.mli *)
module type S = sig
  val name : string
  val language_model : string -> (module Language_model.S)
end

type t = (module S)

val language_model : t -> string -> Language_model.t
val name : t -> string
```

**Step 3: Implement Middleware**

```ocaml
(* middleware.mli *)
module type S = sig
  val wrap_generate :
    generate:(Call_options.t -> Generate_result.t Lwt.t) ->
    Call_options.t ->
    Generate_result.t Lwt.t

  val wrap_stream :
    stream:(Call_options.t -> Stream_result.t Lwt.t) ->
    Call_options.t ->
    Stream_result.t Lwt.t
end

val apply : (module S) -> Language_model.t -> Language_model.t
```

**Step 4: No tests needed for pure signatures.** The module type definitions are
verified by the compiler. Tests come when we build a concrete implementation (Task 2.x).

**Step 5: Format, build, commit**

```bash
dune build  # Verifies all signatures are well-formed
ocamlformat -i lib/ai_provider/*.ml lib/ai_provider/*.mli
git add lib/ai_provider/
git commit -m "feat(ai_provider): add Language_model, Provider, Middleware signatures"
```

---

### Task 1.7: Final re-export and integration test

**Files:**
- Modify: `lib/ai_provider/ai_provider.ml`
- Create: `test/ai_provider/test_integration.ml`
- Modify: `test/ai_provider/dune`

**Step 1: Ensure `ai_provider.ml` re-exports all modules**

```ocaml
module Provider_options = Provider_options
module Finish_reason = Finish_reason
module Usage = Usage
module Warning = Warning
module Provider_error = Provider_error
module Prompt = Prompt
module Tool = Tool
module Tool_choice = Tool_choice
module Mode = Mode
module Content = Content
module Call_options = Call_options
module Generate_result = Generate_result
module Stream_part = Stream_part
module Stream_result = Stream_result
module Language_model = Language_model
module Provider = Provider
module Middleware = Middleware
```

**Step 2: Write integration test — mock provider**

Create a trivial mock provider that implements `Language_model.S` to prove
the signatures work end-to-end:

```ocaml
(* test/ai_provider/test_integration.ml *)

module Mock_model : Ai_provider.Language_model.S = struct
  let specification_version = "V3"
  let provider = "mock"
  let model_id = "mock-v1"

  let generate _opts =
    Lwt.return
      Ai_provider.Generate_result.
        {
          content = [ Content.Text { text = "hello" } ];
          finish_reason = Finish_reason.Stop;
          usage = { Usage.input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
          warnings = [];
          provider_metadata = Provider_options.empty;
          request = { body = `Null };
          response = { id = Some "r1"; model = Some "mock-v1"; headers = []; body = `Null };
        }

  let stream _opts =
    let stream, push = Lwt_stream.create () in
    push (Some (Ai_provider.Stream_part.Text { text = "hello" }));
    push (Some (Ai_provider.Stream_part.Finish {
      finish_reason = Finish_reason.Stop;
      usage = { Usage.input_tokens = 10; output_tokens = 5; total_tokens = Some 15 };
    }));
    push None;
    Lwt.return
      Ai_provider.Stream_result.{ stream; warnings = []; raw_response = None }
end

let test_mock_generate () =
  let model : Ai_provider.Language_model.t = (module Mock_model) in
  let opts = Ai_provider.Call_options.default
    ~prompt:[ Ai_provider.Prompt.System { content = "hi" } ] in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  Alcotest.(check string) "finish" "Stop"
    (Ai_provider.Finish_reason.to_string result.finish_reason)

let test_mock_stream () =
  let model : Ai_provider.Language_model.t = (module Mock_model) in
  let opts = Ai_provider.Call_options.default
    ~prompt:[ Ai_provider.Prompt.System { content = "hi" } ] in
  let result = Lwt_main.run (Ai_provider.Language_model.stream model opts) in
  let parts = Lwt_main.run (Lwt_stream.to_list result.stream) in
  Alcotest.(check int) "2 parts" 2 (List.length parts)

let () =
  Alcotest.run "Integration"
    [
      ( "mock_provider",
        [
          Alcotest.test_case "generate" `Quick test_mock_generate;
          Alcotest.test_case "stream" `Quick test_mock_stream;
        ] );
    ]
```

**Step 3: Run all tests, format, commit**

```bash
dune runtest
ocamlformat -i lib/ai_provider/*.ml lib/ai_provider/*.mli test/ai_provider/*.ml
dune build
git add lib/ai_provider/ test/ai_provider/
git commit -m "feat(ai_provider): complete provider abstraction layer with integration test"
```

---

## Group 2: Anthropic Provider — Foundation

### Task 2.1: Package setup + Config + Model_catalog

**Design ref:** `anthropic-provider-design.md` Sections 2, 3

**Files:**
- Create: `lib/ai_provider_anthropic/dune`
- Create: `lib/ai_provider_anthropic/config.ml` + `.mli`
- Create: `lib/ai_provider_anthropic/model_catalog.ml` + `.mli`
- Create: `lib/ai_provider_anthropic/ai_provider_anthropic.ml`
- Create: `test/ai_provider_anthropic/dune`
- Create: `test/ai_provider_anthropic/test_config_catalog.ml`

**Step 1: Create dune file**

```lisp
(library
 (name ai_provider_anthropic)
 (public_name ocaml-ai-sdk.ai_provider_anthropic)
 (libraries ai_provider lwt lwt.unix cohttp-lwt-unix yojson devkit)
 (preprocess
  (pps lwt_ppx ppx_deriving_yojson ppx_deriving.show)))
```

**Step 2: Write tests**

Test cases:
- `Config.create ()` reads `ANTHROPIC_API_KEY` env var
- `Config.create ~api_key:"sk-test" ()` uses explicit key
- `Config.create ()` with no env var and no explicit key: `api_key_exn` raises
- `Model_catalog.to_model_id Claude_opus_4_6` = `"claude-opus-4-6"`
- `Model_catalog.of_model_id "claude-opus-4-6"` = `Claude_opus_4_6`
- `Model_catalog.of_model_id "some-future-model"` = `Custom "some-future-model"`
- `Model_catalog.capabilities Claude_opus_4_6` has `supports_thinking = true`
- `Model_catalog.capabilities Claude_haiku_4_5` has correct `max_output_tokens`

**Step 3: Implement Config and Model_catalog per design doc**

Model ID mapping (validated against Anthropic docs March 2026):
```
Claude_opus_4_6    -> "claude-opus-4-6"
Claude_sonnet_4_6  -> "claude-sonnet-4-6"
Claude_haiku_4_5   -> "claude-haiku-4-5-20251001"
Claude_sonnet_4_5  -> "claude-sonnet-4-5-20250929"
Claude_opus_4_5    -> "claude-opus-4-5-20251101"
Claude_opus_4_1    -> "claude-opus-4-1-20250805"
Claude_sonnet_4    -> "claude-sonnet-4-20250514"
Claude_opus_4      -> "claude-opus-4-20250514"
```

Also accept aliases in `of_model_id`:
```
"claude-haiku-4-5" -> Claude_haiku_4_5
"claude-sonnet-4-0" -> Claude_sonnet_4
"claude-opus-4-0" -> Claude_opus_4
"claude-sonnet-4-5" -> Claude_sonnet_4_5
"claude-opus-4-5" -> Claude_opus_4_5
"claude-opus-4-1" -> Claude_opus_4_1
```

**Step 4: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider_anthropic): add Config and Model_catalog"
```

---

### Task 2.2: Thinking + Cache_control + Anthropic_options

**Design ref:** `anthropic-provider-design.md` Sections 4.1, 4.2, 4.3, 4.4

**Files:**
- Create: `lib/ai_provider_anthropic/thinking.ml` + `.mli`
- Create: `lib/ai_provider_anthropic/cache_control.ml` + `.mli`
- Create: `lib/ai_provider_anthropic/anthropic_options.ml` + `.mli`
- Create: `lib/ai_provider_anthropic/cache_control_options.ml` + `.mli`
- Create: `test/ai_provider_anthropic/test_anthropic_types.ml`
- Modify: `test/ai_provider_anthropic/dune`

**Step 1: Write tests**

Test cases:
- `Thinking.budget 1024` returns `Ok _`
- `Thinking.budget 1023` returns `Error _`
- `Thinking.budget 0` returns `Error _`
- `Thinking.budget_exn 512` raises `Invalid_argument`
- `Cache_control.ephemeral` constructs successfully
- `Anthropic_options.default` has sensible defaults
- `Anthropic_options.to_provider_options` / `of_provider_options` round-trips
- `Cache_control_options.with_cache_control` / `get_cache_control` round-trips
- GADT isolation: `Anthropic_options.of_provider_options Provider_options.empty` = `None`

**Step 2: Implement**

Key: `Thinking.budget_tokens` is `private int`:
```ocaml
(* thinking.mli *)
type budget_tokens = private int
val budget : int -> (budget_tokens, string) result
val budget_exn : int -> budget_tokens
val to_int : budget_tokens -> int

type t = { enabled : bool; budget_tokens : budget_tokens }
```

```ocaml
(* thinking.ml *)
type budget_tokens = int
let budget n = if n >= 1024 then Ok n else Error (Printf.sprintf "thinking budget must be >= 1024, got %d" n)
let budget_exn n = match budget n with Ok v -> v | Error msg -> invalid_arg msg
let to_int n = n
type t = { enabled : bool; budget_tokens : budget_tokens }
```

Key: GADT registration:
```ocaml
(* anthropic_options.ml *)
type _ Ai_provider.Provider_options.key += Anthropic : t Ai_provider.Provider_options.key
```

```ocaml
(* cache_control_options.ml *)
type _ Ai_provider.Provider_options.key += Cache : Cache_control.t Ai_provider.Provider_options.key
```

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider_anthropic): add Thinking, Cache_control, Anthropic_options with GADT keys"
```

---

## Group 3: Anthropic Provider — Conversion Layer

### Task 3.1: Convert_prompt

**Design ref:** `anthropic-provider-design.md` Section 5

**Files:**
- Create: `lib/ai_provider_anthropic/convert_prompt.ml` + `.mli`
- Create: `test/ai_provider_anthropic/test_convert_prompt.ml`
- Modify: `test/ai_provider_anthropic/dune`

**Step 1: Write tests**

Test cases:
- Single system message extracted to `system` param
- Multiple system messages concatenated
- User text message converts to `{"role": "user", "content": [{"type": "text", "text": "..."}]}`
- Assistant text message converts correctly
- Tool result converts with `tool_use_id`
- Alternating user/assistant messages pass through unchanged
- **Grouping**: consecutive user messages merged into one
- **Grouping**: two user messages in a row get grouped
- Empty message list produces empty output
- File part with `Base64` data converts to Anthropic image source format
- Reasoning part converts to thinking block
- Cache control on a text part flows through via `Provider_options`

**Step 2: Implement**

Key functions:
- `extract_system : Prompt.message list -> string option * Prompt.message list`
- `group_messages : Prompt.message list -> anthropic_message list`
- `convert : system_message:string option -> messages:Prompt.message list -> ...`

Use `Cache_control_options.get_cache_control` to extract cache control from
each part's `provider_options`.

**Context7 check:** Before implementing, verify `Yojson.Safe` API for JSON
construction (`\`Assoc`, `\`String`, `\`List`, etc.) against context7 for
yojson 2.2.2.

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider_anthropic): add prompt conversion with message grouping"
```

---

### Task 3.2: Convert_tools

**Design ref:** `anthropic-provider-design.md` Section 6

**Files:**
- Create: `lib/ai_provider_anthropic/convert_tools.ml` + `.mli`
- Create: `test/ai_provider_anthropic/test_convert_tools.ml`
- Modify: `test/ai_provider_anthropic/dune`

**Step 1: Write tests**

Test cases:
- Single tool converts to Anthropic format with `input_schema`
- `Tool_choice.Auto` -> `Tc_auto`
- `Tool_choice.Required` -> `Tc_any`
- `Tool_choice.None_` -> tools omitted (returns empty list + None)
- `Tool_choice.Specific { tool_name = "foo" }` -> `Tc_tool { name = "foo" }`
- Tool with cache control on `provider_options` gets `cache_control` field
- Empty tool list returns empty list

**Step 2: Implement per design doc**

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider_anthropic): add tool conversion"
```

---

### Task 3.3: Convert_response + Convert_usage

**Design ref:** `anthropic-provider-design.md` Sections 7, and Usage mapping

**Files:**
- Create: `lib/ai_provider_anthropic/convert_response.ml` + `.mli`
- Create: `lib/ai_provider_anthropic/convert_usage.ml` + `.mli`
- Create: `lib/ai_provider_anthropic/anthropic_error.ml` + `.mli`
- Create: `test/ai_provider_anthropic/test_convert_response.ml`
- Modify: `test/ai_provider_anthropic/dune`

**Step 1: Write tests**

Test cases:
- Parse a minimal Anthropic JSON response into `anthropic_response`
- `map_stop_reason (Some "end_turn")` = `Stop`
- `map_stop_reason (Some "max_tokens")` = `Length`
- `map_stop_reason (Some "tool_use")` = `Tool_calls`
- `map_stop_reason None` = `Unknown`
- `to_generate_result` maps text content blocks
- `to_generate_result` maps tool_use content blocks
- `to_generate_result` maps thinking content blocks to Reasoning
- Usage conversion: `cache_read_input_tokens` and `cache_creation_input_tokens` preserved in provider_metadata
- Error parsing: 401 body parses to `Authentication_error`
- Error parsing: 429 body parses to `Rate_limit_error`
- `is_retryable Rate_limit_error` = true
- `is_retryable Authentication_error` = false

**Step 2: Implement**

Key: Anthropic response JSON parsing. Use `ppx_deriving_yojson` for the
internal types where possible, manual parsing where the "type" discriminator
pattern is needed (same as claude-agent-sdk's `content_block_of_yojson`).

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider_anthropic): add response/usage/error conversion"
```

---

### Task 3.4: SSE parser + Convert_stream

**Design ref:** `anthropic-provider-design.md` Section 8

**Files:**
- Create: `lib/ai_provider_anthropic/sse.ml` + `.mli`
- Create: `lib/ai_provider_anthropic/convert_stream.ml` + `.mli`
- Create: `test/ai_provider_anthropic/test_sse.ml`
- Create: `test/ai_provider_anthropic/test_convert_stream.ml`
- Modify: `test/ai_provider_anthropic/dune`

**Step 1: Write SSE parser tests**

Test cases:
- `"event: message_start\ndata: {...}\n\n"` parses to `Message_start`
- `"event: content_block_start\ndata: {...}\n\n"` parses correctly
- `"event: content_block_delta\ndata: {...}\n\n"` with text delta
- `"event: content_block_delta\ndata: {...}\n\n"` with input_json delta
- `"event: ping\ndata: {}\n\n"` parses to `Ping`
- `": comment\n"` ignored (returns None)
- Empty lines ignored
- Multi-line data field (multiple `data:` lines concatenated)

**Step 2: Write stream transformer tests**

Test cases:
- Text streaming: `message_start` -> `content_block_start(text)` -> N x `content_block_delta(text)` -> `content_block_stop` -> `message_delta` -> `message_stop` produces `[Stream_start; Text; Text; ...; Finish]`
- Tool call streaming: accumulates JSON deltas, emits `Tool_call_delta` parts
- Thinking streaming: emits `Reasoning` parts
- Error event produces `Error` stream part

**Step 3: Implement SSE parser**

~50 lines. Stateful line accumulator:
- Track current `event:` type and `data:` buffer
- On blank line, emit parsed event
- Parse JSON data based on event type

**Context7 check:** Verify `Lwt_stream.create`, `Lwt_stream.from`,
`Lwt_stream.map_s` APIs against context7 for lwt 5.9.2.

**Step 4: Implement stream transformer**

Stateful transformer using `Lwt_stream.from` that reads from SSE event stream
and emits `Stream_part.t` values. Maintains a `content_block_state` for tracking
current block type and accumulated tool call args.

**Step 5: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider_anthropic): add SSE parser and stream transformer"
```

---

## Group 4: Anthropic Provider — HTTP + Model + Factory

### Task 4.1: Anthropic_api (HTTP client)

**Design ref:** `anthropic-provider-design.md` Section 9

**Files:**
- Create: `lib/ai_provider_anthropic/anthropic_api.ml` + `.mli`
- Create: `lib/ai_provider_anthropic/beta_headers.ml` + `.mli`
- Create: `test/ai_provider_anthropic/test_api.ml`
- Modify: `test/ai_provider_anthropic/dune`

**Step 1: Write tests**

Test cases:
- `make_request_body` produces valid JSON with required fields
- `make_request_body` with `~stream:true` includes `"stream": true`
- `make_request_body` with thinking config includes thinking params
- `make_request_body` omits `None` optional fields
- `Beta_headers.required_betas` returns correct beta strings
- `Beta_headers.merge_beta_headers` deduplicates

**Step 2: Implement**

`anthropic_api.ml` has two main functions:
- `make_request_body` — pure function, builds JSON
- `messages` — performs HTTP POST via `Cohttp_lwt_unix.Client.post`

For `messages`:
- Non-streaming: read full body, parse JSON, return `` `Json ``
- Streaming: convert `Cohttp_lwt.Body.t` to line stream, return `` `Stream ``

**Context7 check:** Verify `Cohttp_lwt_unix.Client.post` signature, `Cohttp.Header.of_list`, `Cohttp_lwt.Body.to_string`, body streaming APIs against context7 for cohttp-lwt-unix 5.3.0.

Key: the `fetch_fn` injection for testing. When `Config.fetch` is `Some f`,
use that instead of real HTTP. This allows testing without a server.

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider_anthropic): add HTTP client and beta header management"
```

---

### Task 4.2: Anthropic_model (Language_model.S implementation)

**Design ref:** `anthropic-provider-design.md` Section 10

**Files:**
- Create: `lib/ai_provider_anthropic/anthropic_model.ml` + `.mli`
- Create: `test/ai_provider_anthropic/test_anthropic_model.ml`
- Modify: `test/ai_provider_anthropic/dune`

**Step 1: Write tests (using mock fetch)**

Test cases:
- `generate` with simple text prompt returns text content
- `generate` with tool call response returns tool call content
- `generate` with thinking enabled returns reasoning content
- `generate` emits warning for `frequency_penalty`
- `stream` with mock SSE data returns correct stream parts
- `stream` text accumulation works across deltas

Each test uses `Config.create ~fetch:mock_fetch ()` where `mock_fetch`
returns predefined JSON responses.

**Step 2: Implement**

The `create` function:
```ocaml
val create : config:Config.t -> model:string -> Ai_provider.Language_model.t
```

The `generate` pipeline:
1. `check_unsupported opts` -> warnings
2. `Convert_prompt.extract_system` + `Convert_prompt.convert`
3. `Convert_tools.convert_tools`
4. `Anthropic_api.make_request_body`
5. Apply Anthropic_options (thinking, etc.)
6. `Anthropic_api.messages ~stream:false`
7. `Convert_response.to_generate_result`

The `stream` pipeline:
1-5 same as generate
6. `Anthropic_api.messages ~stream:true`
7. `Sse.sse_stream_of_lines`
8. `Convert_stream.transform_stream`
9. Wrap in `Stream_result.t`

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider_anthropic): add Anthropic_model implementing Language_model.S"
```

---

### Task 4.3: Provider factory + top-level API

**Design ref:** `anthropic-provider-design.md` Section 11

**Files:**
- Modify: `lib/ai_provider_anthropic/ai_provider_anthropic.ml` + create `.mli`
- Create: `test/ai_provider_anthropic/test_factory.ml`
- Modify: `test/ai_provider_anthropic/dune`

**Step 1: Write tests**

Test cases:
- `Ai_provider_anthropic.model "claude-sonnet-4-6"` returns a `Language_model.t`
  with `model_id = "claude-sonnet-4-6"` and `provider = "anthropic"`
- `Ai_provider_anthropic.language_model ~api_key:"sk-test" ~model:"claude-sonnet-4-6" ()`
  returns a configured model
- `Ai_provider_anthropic.create ~api_key:"sk-test" ()` returns a `Provider.t`
- `Provider.name provider` = `"anthropic"`
- `Provider.language_model provider "claude-sonnet-4-6"` returns valid model

**Step 2: Implement the public API**

```ocaml
(* ai_provider_anthropic.mli *)

val create :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  unit ->
  Ai_provider.Provider.t

val language_model :
  ?api_key:string ->
  ?base_url:string ->
  ?headers:(string * string) list ->
  model:string ->
  unit ->
  Ai_provider.Language_model.t

val model : string -> Ai_provider.Language_model.t
(** Convenience: uses [ANTHROPIC_API_KEY] env var and default base URL. *)

(** Re-exports for convenience *)
module Config = Config
module Model_catalog = Model_catalog
module Thinking = Thinking
module Cache_control = Cache_control
module Anthropic_options = Anthropic_options
module Cache_control_options = Cache_control_options
```

**Step 3: Run tests, format, commit**

```bash
git commit -m "feat(ai_provider_anthropic): add provider factory and public API"
```

---

## Group 5: End-to-End Integration

### Task 5.1: End-to-end integration test with mock

**Files:**
- Create: `test/ai_provider_anthropic/test_e2e.ml`
- Modify: `test/ai_provider_anthropic/dune`

**Step 1: Write end-to-end test**

A full test that exercises the complete path through the provider abstraction:

```ocaml
(* Use Ai_provider_anthropic with mock fetch to verify the full pipeline *)
let mock_fetch ~url:_ ~headers:_ ~body:_ =
  Lwt.return (Yojson.Safe.from_string {|
    {"id":"msg_123","type":"message","role":"assistant",
     "content":[{"type":"text","text":"Hello from mock!"}],
     "model":"claude-sonnet-4-6","stop_reason":"end_turn",
     "usage":{"input_tokens":10,"output_tokens":5}}
  |})

let test_full_generate () =
  let model =
    Ai_provider_anthropic.language_model
      ~api_key:"sk-test"
      ~model:"claude-sonnet-4-6"
      (* inject mock via Config *)
      ()
  in
  let opts =
    Ai_provider.Call_options.default
      ~prompt:[ Ai_provider.Prompt.User { content = [
        Ai_provider.Prompt.Text { text = "Hello"; provider_options = Ai_provider.Provider_options.empty }
      ] } ]
  in
  let result = Lwt_main.run (Ai_provider.Language_model.generate model opts) in
  (* Verify through abstraction layer *)
  match result.content with
  | [ Ai_provider.Content.Text { text } ] ->
    Alcotest.(check string) "response text" "Hello from mock!" text
  | _ -> Alcotest.fail "expected single text content"
```

**Step 2: Run all project tests**

```bash
dune runtest
```

Expected: ALL tests pass — both `ai_provider` and `ai_provider_anthropic`.

**Step 3: Format, commit**

```bash
ocamlformat -i test/ai_provider_anthropic/test_e2e.ml
dune build
git add test/ai_provider_anthropic/
git commit -m "test: add end-to-end integration test for Anthropic provider"
```

---

### Task 5.2: Final cleanup and documentation

**Files:**
- Modify: `lib/ai_provider/dune` (verify public_name)
- Modify: `lib/ai_provider_anthropic/dune` (verify public_name)
- Modify: `dune-project` (add ai_provider_anthropic package)
- Create: `lib/ai_provider/ai_provider.mli` (top-level module interface)
- Verify all `.mli` files exist

**Step 1: Add `ai_provider_anthropic` package to dune-project**

```lisp
(package
 (name ai_provider_anthropic)
 (synopsis "Anthropic provider for OCaml AI SDK")
 (description "Claude model support via Anthropic Messages API")
 (depends
  (ocaml (>= 4.14))
  (ocaml-ai-sdk (= :version))
  (cohttp-lwt-unix (>= 5.3))
  (alcotest :with-test)))
```

**Step 2: Verify every `.ml` in `lib/` has a corresponding `.mli`**

```bash
for f in lib/ai_provider/*.ml lib/ai_provider_anthropic/*.ml; do
  mli="${f%.ml}.mli"
  [ -f "$mli" ] || echo "MISSING: $mli"
done
```

Expected: No missing files (some internal modules may intentionally skip `.mli`).

**Step 3: Final full build + test + format**

```bash
ocamlformat -i lib/ai_provider/*.ml lib/ai_provider/*.mli \
  lib/ai_provider_anthropic/*.ml lib/ai_provider_anthropic/*.mli \
  test/ai_provider/*.ml test/ai_provider_anthropic/*.ml
dune build
dune runtest
```

Expected: Everything builds and all tests pass.

**Step 4: Commit**

```bash
git add .
git commit -m "chore: final cleanup — package metadata, mli files, formatting"
```

---

## Task Dependency Graph

```
Group 0: Setup
  0.1 Install deps + ocamlformat
    │
Group 1: Provider Abstraction (ai_provider)
    ├── 1.1 Provider_options (GADT)
    ├── 1.2 Finish_reason, Usage, Warning, Provider_error
    ├── 1.3 Prompt types
    ├── 1.4 Tool, Mode, Content
    │    │
    │    └── 1.5 Call_options, Generate_result, Stream_part, Stream_result
    │         │
    │         └── 1.6 Language_model, Provider, Middleware signatures
    │              │
    │              └── 1.7 Integration test (mock provider)
    │
Group 2: Anthropic Foundation
    ├── 2.1 Config + Model_catalog
    └── 2.2 Thinking + Cache_control + Anthropic_options
         │
Group 3: Anthropic Conversion
    ├── 3.1 Convert_prompt
    ├── 3.2 Convert_tools
    ├── 3.3 Convert_response + Convert_usage + Anthropic_error
    └── 3.4 SSE parser + Convert_stream
         │
Group 4: Anthropic HTTP + Model
    ├── 4.1 Anthropic_api (HTTP client)
    │    │
    │    └── 4.2 Anthropic_model (Language_model.S impl)
    │         │
    │         └── 4.3 Provider factory + public API
    │
Group 5: Integration
    ├── 5.1 E2E integration test
    └── 5.2 Final cleanup
```

**Parallelizable within groups:**
- Group 1: Tasks 1.1–1.4 are independent (can run in parallel)
- Group 2: Tasks 2.1 and 2.2 are independent
- Group 3: Tasks 3.1–3.3 are independent (3.4 depends on knowing stream types)

**Cross-group dependencies:**
- Group 2 depends on Group 1 (needs `ai_provider` types)
- Group 3 depends on Groups 1 + 2 (needs both abstraction types and Anthropic types)
- Group 4 depends on Group 3 (needs conversion functions)
- Group 5 depends on Group 4 (needs complete implementation)
