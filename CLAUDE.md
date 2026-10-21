# Muse Desktop (Dom's fork)

Dom's public MIT fork of robzilla1738's `muse-desktop`, the unofficial Electron desktop app for Meta's Muse Code CLI. It adds diff review, Muse-created worktree conversations, an MCP servers tab and two bridges (folder and localhost MCP) that let another agent, such as the Muse app, drive Muse Code. Electron, React, TypeScript, electron-vite and `@muse-code/sdk`. Not a Plateworks property. The charter is `PROJECT_CHARTER.md`.

This file routes and does not restate. Every document is indexed at `docs/README.md`.

## Read this before changing that

| Changing                                                                  | Read first                                                         |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Anything, for the first time                                              | `README.md`, then `docs/architecture.md`                           |
| Any task: a feature, an upstream sync, a bridge, a CLI update, a decision | `docs/changing-things.md`                                          |
| A Muse CLI behavior the extensions rely on                                | `docs/superpowers/plans/2026-10-20-discovery.md`                   |
| A bridge request, tool or security rule                                   | `docs/bridge.md`                                                   |
| A CLI or SDK version                                                      | `docs/compatibility.md`                                            |
| Themes, layout or copy                                                    | `docs/design.md`, `CONTRIBUTING.md`                                |
| Something that looks like a past decision                                 | `docs/decisions.md`                                                |
| How this repo is documented                                               | `docs/superpowers/specs/2026-10-20-documentation-layout-design.md` |

## Invariants

1. **`main` mirrors upstream.** It moves only by `git merge --ff-only upstream/main`. Never commit to it. Features go on branches into the fork's `main` by PR, and Dom merges.
2. **Never push or open a PR upstream unless Dom asks.** The clone's `upstream` push URL is a dead end on purpose, and `gh` defaults to the fork. A PR for upstream comes from `main` and carries none of the fork's own files.
3. **Desktop edits only its own entries in Muse's config.** `~/.config/muse/trust.json` gets one project record. `~/.config/muse/settings.json` keeps every other key, and gets `schema_version: 1` when it has none, which `muse serve` needs to start. Write `enabled: false`, never `disabled` or `transport`.
4. **Tests never touch the real Muse config.** Unit tests write only to temporary folders they are given. The integration script and the e2e launches point `HOME`, `XDG_CONFIG_HOME` and `MUSE_HOME` at a temporary folder. Set all three in every new launch: Muse reads `XDG_CONFIG_HOME` first.
5. **Secrets never reach the renderer.** MCP env values and headers show by name only. The bridge token lives outside the preferences.
6. **Do not package the fork for daily use.** It still carries upstream's `appId` and Sparkle feed, so it would share the installed app's data and update to upstream's build.

## Working here

- Run `npm run dev:isolated` to develop. It keeps Desktop's data out of an installed app.
- The gate is the six commands in `docs/changing-things.md` ("Prove a change"). Integration and e2e use the echo provider. Set `MUSE_BIN="$(command -v muse)"` so they test the CLI you run.
- The e2e run rewrites `docs/screenshots/*.png`. Run `git checkout -- docs/screenshots` before you commit.
- `npm test` includes `tests/unit/docs.test.ts`, which runs the vendored `scripts/docs_check.py`. It holds this file under 2,000 tokens.
- Commits use the repo's `area: summary` style.

## Session logging

Log every session to the repo `plateworks-session-log`. On Dom's Mac it is checked out at `00-09 System/04 Session Log/` in the workspace; elsewhere, clone it beside this one if it is not present. Its convention file, CONVENTION.md, is self-contained: format, tag set and procedure. If the repo is unreachable, append the entry to `SESSION_LOG.md` here under a heading saying it belongs in the log repo, and say the push is pending.
