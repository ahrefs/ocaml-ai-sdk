# Upstream Dependency Update Log

## Last updated: 2026-04-09

| Package | Version |
|---------|---------|
| `ai` | 6.0.154 |
| `@ai-sdk/react` | 3.0.156 |

## Update procedure

1. Run `npm up` from repo root
2. Check new versions: `jq -r '.packages["node_modules/ai"].version' package-lock.json`
3. Diff changed reference files (see `docs/UPSTREAM_INTEROP.md` for the file list)
4. Update roadmap (`docs/plans/2026-03-26-v2-roadmap.md`, `docs/plans/2026-03-26-v3-roadmap.md`) with any new work items. Make sure not to add new pieces of work to already completed sections, even if the work belongs there. Add it in a way that ensures discoverability.
5. Write analysis to `docs/upstream-bump-analysis-<date>.md` if changes are significant, refer the doc from the roadmap entries.
6. Update this file with the new date and versions

## Update policy

At session start, if working with upstream reference files, check if last update is **older than 15 days**. If so, run the update procedure above before reading reference files.
