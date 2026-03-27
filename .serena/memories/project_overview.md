# OCaml AI SDK - Project Overview

## Purpose
The OCaml AI SDK is a type-safe, provider-agnostic AI model abstraction inspired by Vercel AI SDK. It provides a unified interface for integrating multiple AI providers (currently Anthropic Claude) into OCaml applications.

## Key Concepts
- **Provider Abstraction**: Unified interface for AI models from different providers (Anthropic, potentially OpenAI in future)
- **Language Model Interface**: Core `Language_model.S` module type implemented by each provider
- **Type Safety**: Extensive use of OCaml's type system for correctness
- **Streaming Support**: First-class support for streaming generation
- **Tool Use**: Function calling / tool execution with proper result handling
- **Extended Thinking**: Support for Claude's extended thinking capability
- **Prompt Building**: Type-safe prompt construction with role-constrained message parts
- **Core SDK Layer**: Higher-level abstractions like `Generate_text` and `Stream_text` for common patterns

## Core Architecture

### Module Hierarchy
```
ocaml-ai-sdk (package)
├── lib/ai_provider           (Base provider interfaces & types)
├── lib/ai_provider_anthropic (Anthropic Claude implementation)
└── lib/ai_core               (High-level SDK layer)
```

### Library Structure
- **ai_provider**: Type-safe provider-agnostic base layer
- **ai_provider_anthropic**: Concrete implementation for Anthropic Messages API
- **ai_core**: Higher-level abstractions (Generate_text, Stream_text, UIMessage protocol)
- **examples/**: Usage examples and patterns
- **test/**: Comprehensive test suites

## Tech Stack
- **Language**: OCaml (4.14+)
- **Async**: Lwt (5.9+) for promises and async I/O
- **JSON**: Yojson + Melange.json-native for serialization
- **HTTP**: Cohttp-lwt-unix for HTTP requests
- **Schema**: Jsonschema (0.1+) for validation
- **Utilities**: Devkit (1.20240429+) for strings, web utilities, exceptions
- **Build**: Dune 3.21+ with Melange support
- **PPX**: Lwt_ppx (let%lwt syntax), ppx_deriving.show, melange-json-native.ppx

## Code Style & Conventions
- Use `Option.map`, `Option.bind` and Result combinators over pattern matching
- Use `let*` and `let+` (monadic syntax) for chaining operations
- First-class modules extensively for runtime dispatch
- GADT-based extensible records for provider-specific options
- Type-safe JSON serialization via Melange.json-native
