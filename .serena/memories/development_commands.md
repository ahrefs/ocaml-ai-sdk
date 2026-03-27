# Development Commands

## Build & Test Commands

### Build
```bash
make build
# or
dune build
```

### Run Tests
```bash
make test
# or
dune runtest
```

### Run Tests with Auto-Promotion
```bash
make promote
# or
dune build @runtest --auto-promote
```

### Format Code
```bash
make fmt
# or
dune fmt --auto-promote
```

### Watch Mode (auto-rebuild on changes)
```bash
make watch
# or
dune build -w
```

### Clean Build Artifacts
```bash
make clean
# or
dune clean
```

### Interactive REPL
```bash
make top
# or
dune utop .
```

## Running Examples

Examples are in `examples/` directory. Run with:
```bash
dune exec examples/one_shot.exe         # Basic generation
dune exec examples/generate.exe         # High-level API
dune exec examples/streaming.exe        # Streaming
dune exec examples/tool_use.exe         # Function calling
dune exec examples/thinking.exe         # Extended thinking
dune exec examples/stream_chat.exe      # Chat-based streaming
dune exec examples/chat_server/main.exe # Chat server
```

All examples require `ANTHROPIC_API_KEY` environment variable:
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
dune exec examples/one_shot.exe
```

## Project Dependencies

Key dependencies managed by Dune:
- lwt (>= 5.9) - Async programming
- yojson (>= 2.2) - JSON parsing
- cohttp-lwt-unix (>= 5.3) - HTTP client
- melange-json-native (>= 2.0) - Type-safe JSON
- devkit (>= 1.20240429) - Utilities
- base64 - Base64 encoding (for file data)
- jsonschema (>= 0.1) - JSON Schema validation

## Ocaml Language Server Setup

The project uses OCaml 4.14+ with Opam. Language server requires:
```bash
opam switch show
opam exec -- ocaml -version
```

If no switch is set:
```bash
opam switch list                    # See available switches
opam switch create ocaml-ai-sdk 5.2.0  # Create new switch
```

## Code Style Enforcement

- Format: `ocamlformat` (auto-formatting via `dune fmt`)
- Linting: Static analysis tools in test suite
- Dialects: Project uses MLX dialect (Melange) in some files
- PPX Extensions: lwt_ppx, melange-json-native.ppx, ppx_deriving.show

## File Organization

```
ocaml-ai-sdk-w1/
├── Makefile              # Development targets
├── dune-project          # Project config, package definitions
├── lib/
│   ├── ai_provider/      # Base provider interfaces
│   ├── ai_provider_anthropic/  # Anthropic implementation
│   └── ai_core/          # High-level SDK
├── examples/             # Example usage
├── test/                 # Test suites
├── bin/                  # CLI tools (if any)
├── bindings/             # Melange bindings (ai-sdk-react)
└── docs/                 # Documentation
```

## Testing

Test suites in `test/` directory:
- `test/ai_provider/` - Provider interface tests
- `test/ai_provider_anthropic/` - Anthropic-specific tests
- `test/ai_core/` - Core SDK tests

Run specific tests:
```bash
dune exec test/ai_provider_anthropic/test_anthropic_model.exe
dune exec test/ai_provider_anthropic/test_e2e.exe
```

## OPAM Package Management

Packages defined in `dune-project`:
1. **ocaml-ai-sdk** (main) - Provider abstraction + Anthropic implementation
2. **claude_agent_sdk** - Port of official Claude Agent SDK
3. **ai-sdk-react** - Melange bindings for React hooks

Generated .opam files from dune-project:
```bash
dune build # Auto-generates .opam files
```

## Common Development Workflows

### Adding a New Module to ai_provider_anthropic
1. Create `lib/ai_provider_anthropic/my_module.ml(i)`
2. Add to dune file if needed (usually auto-discovered)
3. Export from `ai_provider_anthropic.ml(i)`
4. Update tests in `test/ai_provider_anthropic/`

### Adding Provider-Specific Options
1. Define GADT key in module: `type _ Ai_provider.Provider_options.key += | MyProvider : t Ai_provider.Provider_options.key`
2. Implement `to_provider_options` and `of_provider_options`
3. Extract with `Provider_options.find` in language model implementation

### Testing with Custom HTTP
Config supports custom `fetch_fn`:
```ocaml
let custom_fetch ~url ~headers ~body = 
  (* Return mock response *)
  Lwt.return (Yojson.Basic.from_string mock_json)
in
let config = Config.create ~fetch:custom_fetch () in
let model = Anthropic_model.create ~config ~model:"claude-sonnet-4-6" in
```
