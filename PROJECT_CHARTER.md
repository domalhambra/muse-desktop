# Project charter: Muse Desktop (Dom's fork)

Chartered 2026-10-20.

## What it is

Dom's fork of robzilla1738's Muse Desktop, the unofficial Electron app for Meta's Muse Code CLI. The fork adds four things upstream lacks: diff review in the inspector, conversations in Muse-created worktrees, an MCP servers tab, and two bridges that let another agent, such as the Muse app, ask Muse Code to work. It also holds mMac, a native SwiftUI app in `mac/` over the same core. mMac's M0 was built on 2026-10-21. It sits in `40-49 Outside Work` and is not a Plateworks property.

## Why

Dom wants to run Muse Desktop on his Mac and keep adding features to it. The extensions make it faster to review what Muse changed, safer to let Muse work on a branch, and possible to hand Muse Code a job from the Muse app.

## Done

- **v1, for Dom:** the four extensions run on his Mac against a real model, from the checkout. Every gate command passes on macOS. Dom has seen each feature work.
- **Later, only if it earns it:** a packaged build with its own app ID, signing identity and update feed. Or PRs upstream, one feature at a time, if robzilla1738 wants them.

## Status (2026-10-21)

The extensions are on `extensions`, draft PR 1. Every gate command in `docs/changing-things.md` ("Prove a change") passes on macOS 27.2 with Muse Code 1.4.11 and the echo provider. mMac M0, the headless backend and a bare window, is on `mac-app`. A real model, approvals and the Muse app's reach to the MCP bridge are not verified yet.

## Boundaries

- `main` mirrors upstream. The fork's work goes on branches into the fork by PR.
- Desktop changes only its own entries in Muse's config.
- No upstream PR and no packaged release without Dom's call.

## Where things are

- Clone: `40-49 Outside Work/42 Muse Desktop` in the workspace.
- GitHub: `muse-desktop` in Dom's account, public. Upstream: robzilla1738's `muse-desktop`.
- Router: `CLAUDE.md`. Decisions: `docs/decisions.md`.
