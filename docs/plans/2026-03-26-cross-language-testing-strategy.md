# Cross-Language Testing Strategy

> Verify the OCaml AI SDK produces output that the Vercel AI SDK frontend
> can consume correctly, and detect breakage when upstream changes.

---

## Problem

We have OCaml-side unit tests that verify chunk serialization against
hardcoded strings. But we have no guarantee that:

1. Our SSE output actually parses correctly through `processUIMessageStream`
2. The parsed UIMessages have the expected structure for `useChat()`
3. Upstream SDK updates don't break compatibility

The upstream `vercel/ai` repo has **102 test files** with comprehensive
protocol coverage. We should leverage these rather than reimplementing
validation logic from scratch.

---

## Strategy: Two Test Layers + Drift Detection

The contract between OCaml backend and JS frontend has two directions:

1. **Backend → Frontend (SSE output):** Our chunks must parse correctly
   through `processUIMessageStream` / `readUIMessageStream`
2. **Frontend → Backend (request parsing):** Our `server_handler` must
   accept the same request formats that `useChat()` sends

Both are testable with fixtures and a shared protocol matrix — no HTTP
server needed. We test at the serialization boundary, not through the
network stack.

### Layer 1: Golden SSE Fixtures (OCaml ↔ Node.js)

**Idea:** Extract SSE byte streams from the upstream test suite as fixtures.
Our OCaml tests produce SSE output → feed it through the real
`processUIMessageStream` / `readUIMessageStream` from `ai@6` in Node.js →
assert on the resulting UIMessage objects.

**Why this works:** The wire format (SSE `data: {json}\n\n`) is the
contract boundary. Both sides speak it. We test at the boundary.

```
┌──────────────────┐         SSE bytes          ┌──────────────────┐
│  OCaml ai_core   │ ──── data: {...}\n\n ────→ │  Node.js ai@6    │
│                  │                             │                  │
│  Ui_message_chunk│                             │ processUIMessage │
│  → to_json       │                             │ Stream           │
│  → SSE encode    │                             │ → UIMessage[]    │
└──────────────────┘                             └──────────────────┘
        ↑ assert OCaml-side                              ↑ assert Node-side
```

**Implementation:**

```
test/interop/
├── package.json            # ai@6, vitest
├── fixtures/               # Shared SSE fixtures (generated + hand-written)
│   ├── text-generation.sse
│   ├── tool-roundtrip.sse
│   ├── reasoning-blocks.sse
│   ├── structured-output.sse
│   ├── multi-step-tools.sse
│   ├── error-mid-stream.sse
│   ├── data-parts.sse
│   └── ...
├── generate-fixtures.ml    # OCaml script: produce SSE fixtures from chunks
├── consume-fixtures.test.ts # Node.js vitest: feed SSE fixtures through ai@6
└── request-fixtures.test.ts # Node.js vitest: generate request JSON via useChat internals
```

**Fixture format:** Raw SSE bytes, one file per scenario. Each fixture has
a companion `.expected.json` with the expected UIMessage output after
processing through `readUIMessageStream`.

```
# text-generation.sse
data: {"type":"start","messageId":"msg_1"}

data: {"type":"start-step"}

data: {"type":"text-start","id":"txt_1"}

data: {"type":"text-delta","id":"txt_1","delta":"Hello"}

data: {"type":"text-delta","id":"txt_1","delta":" world!"}

data: {"type":"text-end","id":"txt_1"}

data: {"type":"finish-step"}

data: {"type":"finish","finishReason":"stop"}

data: [DONE]

```

```json
// text-generation.expected.json
{
  "id": "msg_1",
  "role": "assistant",
  "parts": [
    { "type": "text", "text": "Hello world!" }
  ],
  "status": "done"
}
```

---

### Layer 2: Upstream Test Port (Protocol Compliance)

**Idea:** Port the upstream `processUIMessageStream` test scenarios to
OCaml-side fixtures. The upstream tests define exactly which chunk sequences
are valid and what UIMessage state they produce. We extract these as a
machine-readable test matrix.

**Upstream test files to port from:**

| Upstream test file | What it covers | Priority |
|-------------------|----------------|----------|
| `src/ui/process-ui-message-stream.test.ts` | Full protocol: text, reasoning, tools, metadata, errors, malformed streams | Critical |
| `src/ui-message-stream/read-ui-message-stream.test.ts` | Stream → UIMessage conversion, error termination | Critical |
| `src/ui-message-stream/create-ui-message-stream.test.ts` | Writer API, merge, onFinish, persistence | High (after v2 #2) |
| `src/generate-text/output.test.ts` | Output API parsing, schema validation, partial JSON | High |
| `src/generate-text/stream-text.test.ts` | Full streamText scenarios (400+ lines) | High |
| `src/generate-text/generate-text.test.ts` | generateText with tools, output, multi-step | High |
| `src/generate-text/smooth-stream.test.ts` | smoothStream buffering | Medium (after v2 #5) |
| `src/generate-text/parse-tool-call.test.ts` | Tool call parsing edge cases | Medium |
| `src/generate-text/prune-messages.test.ts` | Message pruning | Low (v3) |
| `src/util/parse-partial-json.test.ts` | Partial JSON repair | High |
| `src/util/fix-json.test.ts` | JSON repair edge cases | High |
| `src/util/cosine-similarity.test.ts` | Vector similarity | Low (v3) |
| `src/util/retry-with-exponential-backoff.test.ts` | Retry logic | Medium (after v2 #8) |

**Process:**
1. Read each upstream test file
2. Extract the chunk sequences and expected outputs
3. Create a JSON test matrix (`test/interop/protocol-matrix.json`)
4. OCaml test runner reads the matrix, produces SSE, asserts on JSON output
5. Node.js test runner reads the matrix, feeds SSE through `ai@6`, asserts same

Both sides run the same test cases — if they agree, we're compatible.

**Protocol matrix format:**

```json
{
  "tests": [
    {
      "name": "text streaming",
      "source": "process-ui-message-stream.test.ts",
      "chunks": [
        { "type": "start", "messageId": "msg_1" },
        { "type": "start-step" },
        { "type": "text-start", "id": "txt_1" },
        { "type": "text-delta", "id": "txt_1", "delta": "Hello, " },
        { "type": "text-delta", "id": "txt_1", "delta": "world!" },
        { "type": "text-end", "id": "txt_1" },
        { "type": "finish-step" },
        { "type": "finish", "finishReason": "stop" }
      ],
      "expected_messages": [
        {
          "id": "msg_1",
          "role": "assistant",
          "parts": [{ "type": "text", "text": "Hello, world!" }]
        }
      ]
    },
    {
      "name": "tool roundtrip",
      "source": "process-ui-message-stream.test.ts",
      "chunks": ["..."],
      "expected_messages": ["..."]
    }
  ]
}
```

---

### Request Direction: Frontend → Backend

The other half of the contract. `useChat()` sends JSON request bodies that
our `server_handler` must parse. We need to verify we accept the same
formats the frontend produces.

**What to test:**

| Format | Example | What to verify |
|--------|---------|----------------|
| v6 text parts | `{ "role": "user", "parts": [{ "type": "text", "text": "Hello" }] }` | Parsed as user text message |
| v6 with tool results | `{ "role": "assistant", "parts": [{ "type": "tool-invocation", ... }] }` | Tool call state reconstructed |
| v6 multi-part | `{ "role": "user", "parts": [{ "type": "text", ... }, { "type": "file", ... }] }` | All parts parsed |
| Mixed history | Array with system + user + assistant + tool messages | Full conversation parsed |

**Implementation:**

Request fixtures live in the same `test/interop/fixtures/` directory:

```
fixtures/
├── requests/
│   ├── v6-text.json             # v6 parts array, text only
│   ├── v6-tool-history.json     # v6 with tool invocation parts
│   ├── v6-multi-part.json       # v6 with text + file parts
│   └── mixed-conversation.json  # Full multi-turn conversation
```

Node.js side generates these fixtures by capturing what `useChat()` /
`DefaultChatTransport` actually serializes, ensuring we test against the
real format — not what we think it looks like.

OCaml side reads the same fixtures through `server_handler`'s request
parser and asserts on the resulting `Prompt.message list`. This is a pure
unit test — no HTTP, just JSON → parse → assert.

---

## Upstream Version Pinning and Drift Detection

### Pinned version with upgrade CI

```json
// test/interop/package.json
{
  "name": "ocaml-ai-sdk-interop-tests",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "vitest --run",
    "test:update-fixtures": "node scripts/update-fixtures.mjs"
  },
  "dependencies": {
    "ai": "6.0.116"
  },
  "devDependencies": {
    "vitest": "^3.0.0"
  }
}
```

Pin `ai` to the exact version we've tested against. Add a CI job that:

1. **Weekly:** Bumps `ai` to latest, runs the interop tests
2. **On failure:** Opens a GitHub issue with the failing test name,
   the old version, and the new version
3. **On success:** Auto-commits the version bump

This catches upstream breaking changes before they surprise users.

### Renovate / Dependabot config

```yaml
# .github/dependabot.yml
updates:
  - package-ecosystem: npm
    directory: /test/interop
    schedule:
      interval: weekly
    labels: ["upstream-compat"]
    open-pull-requests-limit: 1
```

---

## Test Scenario Coverage

Derived from the upstream `processUIMessageStream` test suite (14 scenarios)
plus our own additions. Each scenario should exist in both the fixture set
(Layer 1) and the protocol matrix (Layer 2).

| # | Scenario | Upstream source | Chunks | What to assert |
|---|----------|----------------|--------|----------------|
| 1 | Basic text streaming | process-ui-message-stream | start → text-start → text-delta(×N) → text-end → finish | Single text part, correct concatenation |
| 2 | Error chunk | process-ui-message-stream | start → error | Error propagated, no message parts |
| 3 | Malformed: text-delta without text-start | process-ui-message-stream | text-delta (no start) | UIMessageStreamError thrown |
| 4 | Malformed: reasoning-delta without start | process-ui-message-stream | reasoning-delta (no start) | UIMessageStreamError thrown |
| 5 | Malformed: tool-input-delta without start | process-ui-message-stream | tool-input-delta (no start) | UIMessageStreamError thrown |
| 6 | Server-side tool roundtrip | process-ui-message-stream | tool-input-available → tool-output-available → text | Tool part + text part |
| 7 | Tool roundtrip with existing message | process-ui-message-stream | (existing assistant msg) + tool + text | New parts appended, old preserved |
| 8 | Multiple text blocks with tools | process-ui-message-stream | text → tool → text | Multiple text parts, tool between |
| 9 | Reasoning blocks | process-ui-message-stream | reasoning-start → reasoning-delta(×N) → reasoning-end | Reasoning part with text |
| 10 | Tool output error | process-ui-message-stream | tool-input-available → tool-output-error → text | Tool error state, recovery text |
| 11 | Message metadata merging | process-ui-message-stream | start(meta) → message-metadata → finish(meta) | Deep-merged metadata |
| 12 | Metadata after finish | process-ui-message-stream | finish → message-metadata | Late metadata still applied |
| 13 | Tool call streaming (deltas) | process-ui-message-stream | tool-input-start → tool-input-delta(×N) → tool-input-available | Partial JSON → complete input |
| 14 | Reasoning with provider metadata | process-ui-message-stream | reasoning with providerMetadata | Metadata per reasoning block |
| 15 | Structured output (text-delta with JSON) | output.test.ts + our own | text-delta with JSON → parsed object | Output field populated |
| 16 | Multi-step tool loop | stream-text.test.ts | step1: text+tool → step2: tool-result+text | Multiple steps in SSE |
| 17 | Source URL parts | our own | source-url chunk | Source part in message |
| 18 | Data parts (custom) | our own | data chunk with type + id | Data part in message |
| 19 | File parts | our own | file chunk | File part in message |
| 20 | Abort mid-stream | our own | start → text-delta → abort | Abort status |

---

## Implementation Plan

### Phase 1: SSE Fixture Infrastructure (do with v2 item #4)

**Backend → Frontend direction.**

1. Create `test/interop/` directory with `package.json` (ai@6, vitest)
2. Write `test/interop/generate-fixtures.ml` — OCaml script that produces
   `.sse` files from `Ui_message_chunk.t` lists for all 20 scenarios
3. Write `test/interop/consume-fixtures.test.ts` — vitest suite that reads
   each `.sse` file, pipes through `readUIMessageStream`, asserts against
   `.expected.json`
4. Write the 20 fixture pairs (`.sse` + `.expected.json`)
5. Add `dune` rules to build `generate-fixtures.exe`
6. Add CI step: `cd test/interop && npm ci && npm test`

### Phase 2: Protocol Matrix (do with v2 item #4)

**Both directions, shared truth source.**

7. Extract chunk sequences from upstream test files into
   `test/interop/protocol-matrix.json`
8. Write OCaml test that reads the matrix, serializes each scenario's
   chunks to SSE, and validates the JSON output matches
9. Write Node.js test that reads the same matrix, feeds SSE through
   `processUIMessageStream`, validates the same expected output
10. Both tests share the same truth source — if they disagree, we have a bug

### Phase 3: Request Fixtures (do with v2 item #4)

**Frontend → Backend direction.**

11. Write Node.js script that captures the JSON request bodies that
    `useChat()` / `DefaultChatTransport` produces for various scenarios
    (simple text, v6 parts, tool history, multi-turn) and saves them as
    `fixtures/requests/*.json`
12. Write OCaml test that reads each request fixture, feeds it through
    `server_handler`'s request parser, and asserts on the resulting
    `Prompt.message list` — verifying we accept what the frontend sends
13. Cover: v6 text parts, tool invocation parts, file parts,
    reasoning parts, mixed conversations

### Phase 4: Upstream Drift Detection (do after Phase 1-3)

14. Add GitHub Actions workflow for weekly `ai` version bump + test run
15. Configure Dependabot for `test/interop/package.json`
16. Add issue template for upstream compat failures

---

## CI Integration

```yaml
# .github/workflows/interop-tests.yml
name: Interop Tests

on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: '0 6 * * 1'  # Weekly Monday 6am UTC

jobs:
  interop:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: 4.14.x

      - uses: actions/setup-node@v4
        with:
          node-version: 22

      - name: Install OCaml deps
        run: opam install . --deps-only --with-test

      - name: Build fixture generator
        run: opam exec -- dune build test/interop/generate_fixtures.exe

      - name: Generate SSE fixtures
        run: opam exec -- dune exec test/interop/generate_fixtures.exe

      - name: Install Node deps
        working-directory: test/interop
        run: npm ci

      - name: Run fixture tests
        working-directory: test/interop
        run: npm test

      - name: Run OCaml protocol matrix tests
        run: opam exec -- dune runtest test/interop

  upstream-compat:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... same setup ...
      - name: Bump ai to latest
        working-directory: test/interop
        run: npm install ai@latest
      - name: Run tests with latest ai
        working-directory: test/interop
        run: npm test
      - name: Report failure
        if: failure()
        uses: actions/github-script@v7
        with:
          script: |
            const pkg = require('./test/interop/node_modules/ai/package.json');
            github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: `Upstream compat: ai@${pkg.version} breaks interop tests`,
              labels: ['upstream-compat'],
              body: `Weekly test against \`ai@${pkg.version}\` failed.\n\nSee: ${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`,
            });
```

---

## What This Buys Us

1. **Confidence:** Every chunk type we emit is verified by the real upstream
   parser — not just our string assertions. Every request format the
   frontend sends is verified against our parser.
2. **Regression detection:** Upstream changes that break our format are
   caught weekly, with an auto-filed issue
3. **Test derivation:** New upstream test cases can be added to the protocol
   matrix without writing new OCaml code — just add JSON entries
4. **Documentation:** The fixture files serve as executable documentation
   of the wire protocol in both directions
5. **Bidirectional:** Both OCaml and Node.js run the same test matrix,
   catching bugs on either side. Request fixtures ensure we accept what
   `useChat()` actually sends, not what we assume it sends.
6. **No mock server overhead:** Everything is tested at the serialization
   boundary — pure data in, data out. No HTTP servers to start/stop,
   no port conflicts, no timing issues.

---

## Upstream Test Files Reference

For implementing Phase 2, these are the key files to extract test cases from
in the `vercel/ai` repository (`packages/ai/src/`):

| File | Test count | Key scenarios |
|------|-----------|---------------|
| `ui/process-ui-message-stream.test.ts` | ~14 | Core protocol compliance |
| `ui-message-stream/read-ui-message-stream.test.ts` | ~2 | Stream → message conversion |
| `ui-message-stream/create-ui-message-stream.test.ts` | ~15 | Writer API, merge, onFinish |
| `generate-text/stream-text.test.ts` | ~50+ | Full streamText scenarios |
| `generate-text/generate-text.test.ts` | ~40+ | generateText with tools |
| `generate-text/output.test.ts` | ~30 | Structured output parsing |
| `generate-text/smooth-stream.test.ts` | ~10 | Smooth streaming |
| `util/parse-partial-json.test.ts` | ~20 | Partial JSON repair |
| `util/fix-json.test.ts` | ~15 | JSON repair edge cases |

**Request-direction (Frontend → Backend):**

| File | Test count | Key scenarios |
|------|-----------|---------------|
| `ui/convert-to-model-messages.test.ts` | ~20 | UIMessage → model message conversion |
| `ui/validate-ui-messages.test.ts` | ~10 | Message validation edge cases |
| `ui/chat.test.ts` | ~30+ | useChat request body formats |
| `ui/http-chat-transport.test.ts` | ~10 | Transport serialization |
| `generate-text/parse-tool-call.test.ts` | ~15 | Tool call JSON parsing |

The upstream uses **vitest** as test runner and **MockLanguageModelV4** for
mocking. Their mock feeds canned `ReadableStream<LanguageModelV4StreamPart>`
sequences — we don't need to replicate that layer since we test at the
serialization boundary, not the internal model interface.
