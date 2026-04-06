# OpenRouter Playground

Single-page playground that showcases all 6 unique OpenRouter capabilities through an interactive chat with a configurable settings panel.

## Capabilities Demonstrated

1. **Model Selection** -- Choose any OpenRouter model by ID, with optional fallback models
2. **Web Search** -- Enable the web search plugin for grounded answers
3. **Provider Routing** -- Control upstream provider order, fallbacks, and sort strategy
4. **Usage Tracking** -- Enable usage accounting for token counts and cost
5. **Reasoning** -- Configure reasoning effort level and token budget
6. **Extra Body** -- Pass arbitrary JSON fields through to the API

## Setup

```bash
# Set your OpenRouter API key
export OPENROUTER_API_KEY=sk-or-...

# Install client dependencies
cd examples/openrouter-playground
npm install

# Build client (from repo root)
cd ../..
npm run build --prefix examples/openrouter-playground

# Start server
dune exec examples/openrouter-playground/server/main.exe
```

Open http://localhost:28602 in your browser.

## How It Works

The client sends a `X-OpenRouter-Config` JSON header with each chat message containing the current settings. The server parses this header, builds `Openrouter_options.t`, creates a model with the specified ID, and streams the response.

Settings only affect subsequent messages -- changing settings mid-conversation applies to the next message sent.
