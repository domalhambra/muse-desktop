# Documentation layout: Muse Desktop (Dom's fork)

Status: live. Dom approved the rollout on 2026-10-20. Applies `00_Resources/documentation-standard.md` to a fork of a public upstream repo.

## Tier

Medium, plus `PROJECT_CHARTER.md`. The app has more than ten source modules, so it takes `docs/architecture.md` and `docs/changing-things.md`. It is a native app with a release process, which would put it in Large. But the release process is upstream's, and the fork does not release. Upstream's `docs/design.md`, `docs/releasing.md` and `docs/release-readiness.md` fill the design and release roles under their own names. No runbooks or handoffs folder exist, and none is needed yet.

## The fork rule

Every upstream sync must stay cheap. So the fork's documentation is new files wherever possible:

- New: `CLAUDE.md`, `AGENTS.md`, `PROJECT_CHARTER.md`, `docs/README.md`, `docs/decisions.md`, `docs/changing-things.md`, everything under `docs/superpowers/`, `scripts/docs_check.py` and `tests/unit/docs.test.ts`.
- Edited upstream files: `README.md` (one pointer line, one stale claim and two path quotes), `docs/architecture.md` (a module map added at the end) and `docs/compatibility.md` (the extensions' verification line). The extensions had already edited all three.
- Edited fork files: `docs/bridge.md`, which the extensions added. Its quotes of runtime folders now carry a `<bridge folder>` placeholder.
- Kept as is: `README.md`'s structure. It is upstream's public front page, so it does not take the standard's five sections.

## The check

`scripts/docs_check.py` is vendored byte for byte and registered in `00_Resources/VENDORED.md`. `tests/unit/docs.test.ts` spawns it, so `npm test` runs it, as in HD Chart Engine. It runs with `--require` for the three Medium documents and two `--known-absent` entries, both gitignored folders: `release/`, the build output that `README.md` names, and `.cache/`, where upstream's `docs/releasing.md` says the Sparkle tools land.

## Upstream PRs

A PR meant for upstream comes from a branch cut from `main` and carries none of the new files above.
