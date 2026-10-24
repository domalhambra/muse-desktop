# Docs index

Every document under `docs/`, with when to read it. The router is `CLAUDE.md` at the repo root.

## This repo

| Document                                                      | Read when                                                                                                                                                                                 |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `architecture.md`                                             | You need the shape of mMac and its backend, the measured size, the module map, or which file owns a behavior. Upstream's file, rewritten for mMac in M4a.                                 |
| `changing-things.md`                                          | You are about to change anything: one section per task, plus the gate. The fork's own file.                                                                                               |
| `decisions.md`                                                | Something looks like a past decision, or you are about to reverse one. The fork's own file.                                                                                               |
| `bridge.md`                                                   | You are using or changing the folder bridge or the MCP bridge, or teaching the Muse app to use them.                                                                                      |
| `compatibility.md`                                            | You update Muse Code or the SDK, or need a known limit.                                                                                                                                   |
| `design.md`                                                   | You change themes, layout or copy. Upstream's file, rewritten for mMac in M4a.                                                                                                            |
| `superpowers/plans/2026-10-20-discovery.md`                   | You need a Muse CLI fact behind the extensions, or a place where the build differs from the plan.                                                                                         |
| `superpowers/specs/2026-10-20-documentation-layout-design.md` | You change how this repo is documented.                                                                                                                                                   |
| `superpowers/specs/2026-10-21-mac-app-design.md`              | You work on mMac, the SwiftUI app in `mac/`, or its headless backend. Approved. M0 to M5a are built; M4b and M5b are next.                                                                |
| `superpowers/plans/2026-10-21-mmac-m0.md`                     | You check M0, mMac's spike: the headless backend, `MuseBackend` and a bare window. Built 2026-10-21. Ends with what M1 carries.                                                           |
| `superpowers/plans/2026-10-21-mmac-m1.md`                     | You build or check M1, mMac's core loop. Built 2026-10-21. Ends with what M2 carries.                                                                                                     |
| `superpowers/plans/2026-10-21-mmac-m1-electron-survey.md`     | You need Electron's exact strings, calls or edge cases for a mMac feature.                                                                                                                |
| `superpowers/plans/2026-10-21-mmac-m2.md`                     | You build or check M2, mMac's inspector. Built 2026-10-21. Ends with what M3 carries.                                                                                                     |
| `superpowers/plans/2026-10-22-mmac-m3.md`                     | You build or check M3, mMac's Settings window. Built 2026-10-22. Ends with what M4 carries, the live run included.                                                                        |
| `superpowers/specs/2026-10-22-mmac-m4a-design.md`             | You build or check M4a: the last seven parity features, the size measurement, the parity check and the removal of Electron's shell. Approved 2026-10-22 and built 2026-10-23.             |
| `superpowers/plans/2026-10-22-mmac-m4a-survey.md`             | You need Electron's exact strings, calls or limits for ⌘K, pins and archives, export, composer commands, attachments, voice or the open-in actions.                                       |
| `superpowers/plans/2026-10-22-mmac-m4a.md`                    | You build or check M4a. Built 2026-10-23. It holds the interface contract and the tasks, and ends with the Parity report, the Review report and what M4b carries.                         |
| `superpowers/plans/2026-10-23-mmac-m4b.md`                    | You build or check M4b, mMac's proof work: the UI tests for the M4a features, three runs, and the live isolated run. It ends with the first live session's results and fixes.             |
| `superpowers/specs/2026-10-23-mmac-parity-design.md`          | You build or check Desktop parity: the ten features M5a and M5b bring from Claude Code Desktop. Approved 2026-10-23. M5a is built; M5b closes.                                            |
| `superpowers/plans/2026-10-23-mmac-m5a.md`                    | You build or check M5a, the session controls: permission modes, `!` shell, side chat, context and tasks, agents, preview and the shortcuts. Built 2026-10-23. Ends with what M5b carries. |

The extensions plan itself was attached to the cloud session's first message and was never committed. The discovery record holds every difference from it.

## Workspace canon this repo depends on

These live in Dom's workspace, not in this repo.

| Canon                                    | Governs                                                     |
| ---------------------------------------- | ----------------------------------------------------------- |
| `00_Resources/documentation-standard.md` | This layout and the check                                   |
| `00_Resources/ste-writing-standard.md`   | The voice of these documents                                |
| `00_Resources/johnny-decimal-system.md`  | Where the clone lives: `40-49 Outside Work/42 Muse Desktop` |
