# Upstream Dependency Update Log

## Last updated: 2026-10-21

| Package | Version |
|---------|---------|
| `ai` | 6.0.301 |
| `@ai-sdk/react` | 3.0.304 |

The root `package.json` pins both packages to exact v6 versions. This SDK
targets AI SDK v6: the code was modelled on v5 and brought to v6 parity, with
no v7 work. Reading v7 reference files would compare it against APIs and
behaviour it does not aim for.

The 2026-08-04 refresh had moved the reference copy to `ai@7.0.51` /
`@ai-sdk/react@4.0.54` (see `docs/upstream-bump-analysis-2026-08-04.md`).
Pinning brings it back to v6.

## Update policy

The pins do not move on their own, and there is no periodic refresh. Change
them only when deciding to:

- take a newer v6 release, for a fix or behaviour we want to match. Keep `ai`
  and `@ai-sdk/react` a matching pair (`@ai-sdk/react` depends on an exact
  `ai` version), and prefer releases that are at least two weeks old.
- move to v7. That is a project decision, since it means adopting v7 APIs
  and behaviour.

## Update procedure

1. Set the exact versions in the root `package.json`.
2. Run `npm install --ignore-scripts` from the repo root. The packages are
   reference files only, so their install scripts never need to run.
3. Check the installed versions: `jq -r '.packages["node_modules/ai"].version' package-lock.json`
4. Diff changed reference files (see `docs/UPSTREAM_INTEROP.md` for the file list)
5. Update roadmap (`docs/plans/2026-03-26-v2-roadmap.md`, `docs/plans/2026-03-26-v3-roadmap.md`) with any new work items. Make sure not to add new pieces of work to already completed sections, even if the work belongs there. Add it in a way that ensures discoverability.
6. Write analysis to `docs/upstream-bump-analysis-<date>.md` if changes are significant, refer the doc from the roadmap entries.
7. Update this file with the new date and versions
