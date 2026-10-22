# Docs index

Every document under `docs/`, with when to read it. The router is `CLAUDE.md` at the repo root.

## This repo

| Document                                                      | Read when                                                                                                                       |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `architecture.md`                                             | You need the shape of the app, the module map, or which file owns a behavior. Upstream's file, with the fork's sections added.  |
| `changing-things.md`                                          | You are about to change anything: one section per task, plus the gate. The fork's own file.                                     |
| `decisions.md`                                                | Something looks like a past decision, or you are about to reverse one. The fork's own file.                                     |
| `bridge.md`                                                   | You are using or changing the folder bridge or the MCP bridge, or teaching the Muse app to use them.                            |
| `compatibility.md`                                            | You update Muse Code or the SDK, or need a known limit.                                                                         |
| `design.md`                                                   | You change themes, layout or copy. Upstream's file.                                                                             |
| `releasing.md`                                                | You need upstream's signing and release process. The fork does not release. Upstream's file.                                    |
| `release-readiness.md`                                        | You need what upstream verified for 0.2.0. Upstream's file.                                                                     |
| `superpowers/plans/2026-10-20-discovery.md`                   | You need a Muse CLI fact behind the extensions, or a place where the build differs from the plan.                               |
| `superpowers/specs/2026-10-20-documentation-layout-design.md` | You change how this repo is documented.                                                                                         |
| `superpowers/specs/2026-10-21-mac-app-design.md`              | You work on mMac, the SwiftUI app in `mac/`, or its headless backend. Approved. M0 and M1 are built.                            |
| `superpowers/plans/2026-10-21-mmac-m0.md`                     | You check M0, mMac's spike: the headless backend, `MuseBackend` and a bare window. Built 2026-10-21. Ends with what M1 carries. |
| `superpowers/plans/2026-10-21-mmac-m1.md`                     | You build or check M1, mMac's core loop. Built 2026-10-21. Ends with what M2 carries.                                           |
| `superpowers/plans/2026-10-21-mmac-m1-electron-survey.md`     | You need Electron's exact strings, calls or edge cases for a mMac feature.                                                      |

The extensions plan itself was attached to the cloud session's first message and was never committed. The discovery record holds every difference from it.

Other files under `docs/` are not documents: `screenshots/`, `image-prompts.json` and `plush-image-prompt.json` belong to upstream's README and artwork.

## Workspace canon this repo depends on

These live in Dom's workspace, not in this repo.

| Canon                                    | Governs                                                     |
| ---------------------------------------- | ----------------------------------------------------------- |
| `00_Resources/documentation-standard.md` | This layout and the check                                   |
| `00_Resources/ste-writing-standard.md`   | The voice of these documents                                |
| `00_Resources/johnny-decimal-system.md`  | Where the clone lives: `40-49 Outside Work/42 Muse Desktop` |
