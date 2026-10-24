# Muse Desktop (Dom's fork)

Dom's public MIT fork of robzilla1738's `muse-desktop`, the unofficial Electron desktop app for Meta's Muse Code CLI. The fork's app is mMac, a native SwiftUI app in `mac/`. It runs upstream's Node core unchanged, as one backend process (`src/headless/`). Electron's shell left the fork in M4a, on 2026-10-22; `main` still mirrors upstream. The fork adds diff review, Muse-created worktree conversations, an MCP servers tab and two bridges (folder and localhost MCP) that let another agent, such as the Muse app, drive Muse Code. Swift, SwiftUI, TypeScript, Node and `@muse-code/sdk`. Not a Plateworks property. The charter is `PROJECT_CHARTER.md`.

This file routes and does not restate. Every document is indexed at `docs/README.md`.

## Read this before changing that

| Changing                                                                  | Read first                                                                                                            |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Anything, for the first time                                              | `README.md`, then `docs/architecture.md`                                                                              |
| Any task: a feature, an upstream sync, a bridge, a CLI update, a decision | `docs/changing-things.md`                                                                                             |
| A Muse CLI behavior the extensions rely on                                | `docs/superpowers/plans/2026-10-20-discovery.md`                                                                      |
| A bridge request, tool or security rule                                   | `docs/bridge.md`                                                                                                      |
| A CLI or SDK version                                                      | `docs/compatibility.md`                                                                                               |
| Themes, layout or copy                                                    | `docs/design.md`, `CONTRIBUTING.md`                                                                                   |
| Something that looks like a past decision                                 | `docs/decisions.md`                                                                                                   |
| How this repo is documented                                               | `docs/superpowers/specs/2026-10-20-documentation-layout-design.md`                                                    |
| mMac, the app in `mac/`, or its backend in `src/headless/`                | `docs/superpowers/specs/2026-10-21-mac-app-design.md`, then "Change mMac or its backend" in `docs/changing-things.md` |

## Invariants

1. **`main` mirrors upstream.** It moves only by `git merge --ff-only upstream/main`. Never commit to it. Features go on branches into the fork's `main` by PR, and Dom merges.
2. **Never push or open a PR upstream unless Dom asks.** The clone's `upstream` push URL is a dead end on purpose, and `gh` defaults to the fork. A PR for upstream comes from `main` and carries none of the fork's own files.
3. **mMac edits only its own entries in Muse's config.** `~/.config/muse/trust.json` gets one project record. `~/.config/muse/settings.json` keeps every other key, and gets `schema_version: 1` when it has none, which `muse serve` needs to start. Write `enabled: false`, never `disabled` or `transport`.
4. **Tests never touch the real Muse config.** Unit tests write only to temporary folders they are given. The integration and headless scripts and the UI tests point `HOME`, `XDG_CONFIG_HOME` and `MUSE_HOME` at a temporary folder. Set all three in every new launch: Muse reads `XDG_CONFIG_HOME` first.
5. **Secrets stay out of the preferences and the UI.** MCP env values and headers show by name only. The bridge token lives in the login Keychain. No test or script reads Dom's item, `com.domalhambra.mmac.bridge-token`.
6. **An upstream sync keeps Electron's shell deleted.** An upstream change to a file M4a removed arrives as a conflict. Keep the deletion, and port any core change by hand ("Sync with upstream" in `docs/changing-things.md`).

## Working here

- Build and run mMac as "Change mMac or its backend" in `docs/changing-things.md` says. Its data stays in `~/Library/Application Support/mMac`.
- The gate is the commands in `docs/changing-things.md` ("Prove a change"). Integration, headless and the UI tests use the echo provider. Set `MUSE_BIN="$(command -v muse)"` so they test the CLI you run.
- `npm test` includes `tests/unit/docs.test.ts`, which runs the vendored `scripts/docs_check.py`. It holds this file under 2,000 tokens.
- Commits use the repo's `area: summary` style.

## Session logging

Log every session to the repo `plateworks-session-log`. On Dom's Mac it is checked out at `00-09 System/04 Session Log/` in the workspace; elsewhere, clone it beside this one if it is not present. Its convention file, CONVENTION.md, is self-contained: format, tag set and procedure. If the repo is unreachable, append the entry to `SESSION_LOG.md` here under a heading saying it belongs in the log repo, and say the push is pending.
