# Upstream Dependency Bump Analysis

**Date:** 2026-08-04
**Bumped from:** `ai@6.0.154` / `@ai-sdk/react@3.0.156`
**Bumped to:** `ai@7.0.51` / `@ai-sdk/react@4.0.54`

## Impact

The refresh was required because the previous reference snapshot was older
than the repository's 15-day update window. The lockfile update also refreshes
the AI SDK provider packages and adds the current gateway/MCP reference
packages.

The model-reference changes relevant to this feature are the current
Anthropic model IDs and reasoning/effort behavior used to implement the
catalog and request policy in the stacked policy PR. The UI protocol changes
are additive for the paths covered here; no additional OCaml UI schema change
was needed beyond the signature metadata work in the lower stack.

The upstream major-version change is intentionally recorded but not treated as
an invitation to migrate unrelated OCaml APIs. Existing `dune` builds and
tests remain the compatibility check for this repository.

## Dependency versions

| Location | `ai` | `@ai-sdk/react` |
|----------|--------|-------------------|
| Repo root | 7.0.51 | 4.0.54 |

No additional roadmap work was identified from this refresh.
