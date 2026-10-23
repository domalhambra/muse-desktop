# mMac: design

Status: approved. Designed with Dom on 2026-10-21, one section at a time; Dom approved each section and then the written spec.

## Goal

A native SwiftUI app for macOS with the same features as this fork, the four extensions included. It must feel like a Mac app and weigh far less than the Electron build, which is 344 MB on disk and about 229 MB of memory across four processes when idle.

M4a measured both apps on 2026-10-23 on macOS 27.2 (26B5112a), Mac17,2 (arm64), with `mac/scripts/measure-size.sh` at `7095d4d`. mMac's bundle is 16.8 MiB on disk, against Muse Desktop's 344.0 MiB. Outside its bundle, mMac also needs the system Node (226.6 MiB) and the checkout's backend: 0.2 MiB of `src/` and 41.6 MiB of packages in `node_modules`. mMac and its backend use 117.5 MiB of memory (physical footprint) in 3 processes, idle on an empty first screen with a temporary home. Muse Desktop uses 346.7 MiB in 4 processes, measured after 69 seconds with Dom's real projects and conversations, so the two memory numbers are not like-for-like. `muse serve` adds 37.1 MiB to mMac and 40.0 MiB to Muse Desktop; the process totals do not include it. "Size" in `docs/architecture.md` has the table and the method. The 344 MB and 229 MB above are the first figures, from 2026-10-21, with no recorded method.

It does not rewrite the backend. The fork's backend modules run unchanged in one plain Node process. Only the UI is new.

## Decisions

| Decision                                                                                                    | Why                                                                                                                                                                                                |
| ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A SwiftUI app plus a Node backend process, not a Swift rewrite of the backend                               | It reuses about 2,300 lines of tested backend code: Muse, Git, worktrees, MCP settings and both bridges. The official `@muse-code/sdk` keeps doing the protocol work, so nobody ports it to Swift. |
| The backend talks over stdin and stdout, not a local web server or Node embedded in the app                 | No network port and no token for this link. The backend stops with the app. It is the same pattern Desktop uses with `muse serve`.                                                                 |
| A new front door, `src/headless/server.ts`, repeats the wiring of `src/main/index.ts` instead of sharing it | `index.ts` is upstream's busiest file. A shared refactor would conflict on most upstream syncs. A parity test catches drift between the two.                                                       |
| The Electron app stays in the repo, unused by the Mac app                                                   | Upstream syncs stay clean, the Electron build is a fallback until the Mac app reaches parity, and its e2e tests keep guarding the core. Revisit at parity.                                         |
| The app lives in `mac/` inside this fork                                                                    | The backend, upstream syncs and the extensions stay in one repo. The new folder never conflicts with upstream.                                                                                     |
| macOS 15 or newer                                                                                           | Modern SwiftUI, including a native resizable inspector. The app is for Dom's own Mac.                                                                                                              |
| Two themes only: Muse (default) and Moonlight. Both are dark.                                               | Dom's call. Daylight, Grove, Plush and a light mode are dropped. A light option can come later.                                                                                                    |
| The name is mMac, bundle ID `com.domalhambra.mmac`                                                          | Dom's call. It stays clear of upstream's "Muse Desktop" and Meta's "Muse for Mac".                                                                                                                 |
| For Dom's use, the backend runs on the Node already installed on the Mac                                    | Nothing extra ships. A version for other people would bundle Node, and that is out of scope.                                                                                                       |

## Architecture

```text
mMac (SwiftUI)                     one plain Node process             Muse Code CLI
┌────────────────────────┐  stdio  ┌──────────────────────────┐ stdio ┌────────────┐
│ windows, sidebar,      │ ──────> │ src/headless/server.ts   │ ────> │ muse serve │
│ transcript, inspector, │ <────── │ the core in src/main/:   │ <──── │            │
│ Settings, pickers,     │  JSON   │ muse-host, git, files,   │  MSP  └────────────┘
│ alerts, Keychain, mic  │  lines  │ worktrees, mcp-config,   │
└────────────────────────┘         │ bridges, voice, prefs    │
                                   └──────────────────────────┘
```

The Mac app never loads Electron or Chromium. At runtime it is the SwiftUI app plus one Node process.

### Units

| Unit                    | Path                                                                        | Owns                                                                                               | Depends on                      |
| ----------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------- |
| The core                | `src/main/` except `index.ts` and `updates.ts`                              | Everything the backend does today                                                                  | Node, `@muse-code/sdk`, Git     |
| The headless front door | `src/headless/server.ts`, `src/headless/backend.ts`, `src/headless/wire.ts` | Reading requests, calling the core, writing replies, events and Asks                               | The core                        |
| The backend client      | `mac/Packages/MuseBackend/`                                                 | Starting `server.ts`, the four message kinds, typed requests and events in Swift                   | Node on the Mac                 |
| `MuseKit`               | `mac/Packages/MuseKit/`                                                     | Markdown, transcript and sidebar rules, the `Workspace` store, the `Inspector` store and its rules | `MuseBackend`, `swift-markdown` |
| The app                 | `mac/project.yml` (XcodeGen generates the Xcode project), `mac/mMac/`       | All UI and every native service                                                                    | `MuseBackend`                   |

`MuseBackend` has no UI, and the app never writes JSON itself.

## Messages

One JSON object per line, in both directions.

| Kind    | Direction                    | Shape                                                                                                                                           |
| ------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Request | app → backend                | `{"id": 7, "method": "sessions", "args": []}`                                                                                                   |
| Reply   | backend → app                | `{"id": 7, "ok": true, "value": …}` or `{"id": 7, "ok": false, "error": "…"}`                                                                   |
| Event   | backend → app                | `{"event": …}`, an `AppEvent` from `src/shared/protocol.ts`                                                                                     |
| Ask     | backend → app, then answered | `{"ask": 3, "kind": "confirm", "title": "…", "message": "…", "detail": "…", "buttons": ["…", "…"]}`, answered with `{"answer": 3, "choice": 0}` |

Method names and reply shapes are today's IPC channels (`src/preload/index.ts`) and the `{ ok, value | error }` replies that `handle()` in `src/main/index.ts` writes. The first request is `hello`, which carries the protocol number (`HEADLESS_PROTOCOL` in `src/headless/wire.ts`). A mismatch stops the connection with a clear error. The second request, `start`, carries the data folder. Since M3 it also carries the bridge token.

A request the backend cannot read, but whose `id` it can read, gets an `ok: false` Reply, so mMac's call never waits forever. A line with no readable `id` becomes an error Event. An Ask whose id mMac can read, but whose body it cannot, is answered with `-1`, the cancel choice. An Ask with no readable id gets only an error event.

### What moves from the backend to the app

| Today in `index.ts`                                                             | In mMac                                                                                                        |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Trust prompt, "Reconnect while Muse is working?", "Quit while Muse is working?" | Asks. The backend still decides when to ask, and the app shows each one as a sheet on its window.              |
| Project, CLI, attachment and export pickers                                     | The app shows the native panel and sends the chosen path. The backend validates it as today.                   |
| Completion notification                                                         | The app posts it from session events.                                                                          |
| Finder, Terminal, links, revealing a file                                       | The app uses `NSWorkspace`.                                                                                    |
| Microphone capture                                                              | The app records 16 kHz mono WAV (`src/shared/voice.ts` limits) and sends it to the existing transcribe method. |
| The bridge token in a `safeStorage` file                                        | The app keeps the token in the login Keychain and sends it in `start`. A new token goes back to the Keychain.  |
| Window, menus, theme source                                                     | Native SwiftUI and AppKit                                                                                      |
| Sparkle (`updates.ts`)                                                          | Native Sparkle, configured with the app's own feed before any distribution. Off for v1.                        |

The data folder is `~/Library/Application Support/mMac`. The app never reads or writes the Electron app's data.

## Lifecycle and errors

- **Start:** the app finds Node. If Node is missing, it shows a setup screen with the fix. Then it starts `server.ts`, sends `hello` and `start`, and the backend connects to Muse.
- **The backend crashes:** the app shows "The Muse backend stopped" with **Restart**. Conversations are durable in Muse Code, and unsent drafts live in the app, so nothing is lost.
- **The app crashes:** the backend sees stdin close and runs the normal quit path: it stops the bridges and closes `muse serve`. No orphaned process.
- **Quit:** the app sends `shutdown`. If a turn is running, the backend Asks inside that request, and "Keep working" keeps the app open. Once it may quit, the backend replies and starts its quit path. The app waits up to 5 seconds for it to exit, then force-stops it. A second Quit force-stops it at once.
- **Failed requests:** the app shows the backend's error message. Those messages are already written for the user.

## Testing

Every test points `HOME`, `XDG_CONFIG_HOME` and `MUSE_HOME` at a temporary folder.

| Layer         | Proves                                                                                                  | How                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| The core      | The backend still works                                                                                 | The existing unit tests and `npm run test:integration`, unchanged                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `server.ts`   | Hello, a streamed turn, an Ask answered, and a shutdown that leaves no `muse` process                   | A new `scripts/verify-headless.ts` against the real CLI and the echo provider                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Method parity | No method exists in one front door only                                                                 | A unit test that compares the methods in `src/main/index.ts` and `src/headless/server.ts`. Electron-only methods sit on a named list.                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `MuseBackend` | Every message kind is encoded, decoded and routed                                                       | `swift test` against a scripted fake backend                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `MuseKit`     | Markdown, the transcript, sidebar, card and inspector rules, and the `Workspace` and `Inspector` stores | `swift test` against the same scripted fake backend                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| The app       | The main flows work end to end                                                                          | UI tests through `xcodebuild test` in `mac/mMacUITests/MMacUITests.swift`. `testAnEchoConversationEndToEnd` runs the real backend and the echo CLI. `testCardsAgainstTheFakeBackend`, `testTheInspectorReviewsChangesAgainstTheFakeBackend`, `testAnAskShowsOverTheRenameSheet`, `testSettingsAgainstTheFakeBackend` and `testARestartReopensTheConversationWithItsDraft` run `mac/Fixtures/fake-backend.mjs` for approvals, questions, the inspector, Asks, Settings and a backend restart. `mac/scripts/ui-tests.sh` runs them several times and checks mMac's real defaults |

The gate is in "Prove a change" in `docs/changing-things.md`: the six commands the Electron app already had, `npm run test:headless`, `swift test` for `MuseBackend` and for `MuseKit`, and `xcodebuild test`, which builds the app and runs the UI tests.

## Milestones

| Milestone     | Done when                                                                                                                                                                                                                                                                                                                                                     |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| M0: spike     | Done 2026-10-21. `server.ts` and a bare window connect to Muse, list conversations and stream one echo turn. `npm run test:headless` (`scripts/verify-headless.ts`) passes.                                                                                                                                                                                   |
| M1: core loop | Done 2026-10-21. Projects, sidebar, conversation list, streamed transcripts with Markdown and code blocks, composer (send, stop, queue, steer), approvals, questions, model and effort                                                                                                                                                                        |
| M2: inspector | Built 2026-10-22. Its four UI tests passed three runs in a row in M3. Its live run moves to M4. Native resizable inspector: file previews, Git status and diffs, diff review with a labeled **Revert hunk** button on each hunk, worktrees                                                                                                                    |
| M3: Settings  | Built 2026-10-22. The six UI tests passed three runs in a row. After the first review fixes, one more run passed and one failed at launch, when macOS ended AutomationModeUI (jetsam). The last fix commits have not run in a UI test. Dom moved the live run to M4. A macOS Settings window: Muse Code path, MCP servers, bridges, appearance, notifications |
| M4: the rest  | Everything else on the parity checklist                                                                                                                                                                                                                                                                                                                       |

Each milestone is one PR from its own branch into the fork's `extensions` branch: M0 from `mac-app`, M1 from `mac-m1`, M2 from `mac-m2`. Dom merges.

## Parity checklist

Each item names the test that proves it, or the date of a manual check when no test can. It is done when every item is ticked.

- [x] Finds the installed `muse`, including the login-shell environment, and accepts a custom path (M1; `npm run test:integration`, `aCustomCLIPathIsSavedThenReconnectReopens`)
- [x] Streams conversations, reasoning summaries, grouped tool activity and stored output (M1; `TranscriptEntryTests.swift`, `storedOutputIsReadOnce`, the echo UI test)
- [x] Code blocks with a language label and one-click copy (M1; `MarkdownBlockTests.swift`, the echo UI test)
- [x] Opens and resumes sessions; renames them (M1; `aLateOpenReplyIsIgnored`, `sendingToAnOpenedConversationResumesIt`, the echo UI test's rename)
- [x] The CLI's exact approval choices, and agent questions (M1; `CardsTests.swift`, `cardsCallTheBackend`, the fake-backend UI test)
- [x] Cancel, queued follow-ups and steering (M1; `stopCancelsTheOpenConversation`, `steerAndEffortTravelWithTheMessage`)
- [x] Model selection and reasoning effort (M1; `theDefaultModelIsChosenAndModelsChangeWhereTheyShould`, `effortIsSavedAsAPreference`, the fake-backend UI test)
- [x] Imports existing CLI history and discovers its project folders (M1; `historyFollowsEveryPage`, `historyKeepsATitleAndPromptTheListOmits`, the history test in `tests/unit/headless-backend.test.ts`)
- [x] Project trust prompt (M1; `npm run test:headless`, the echo UI test)
- [x] Projects with Git branch and working-tree status badges (M2; `projectBadgesFollowTheRecentProjects`, `gitBadgesSayHowManyChanged`, `aWorktreeConversationReadsItsOwnBadge`)
- [x] File previews with breadcrumbs and file-type icons (M2; `fileKindsFollowElectronsExtensionLists`, `breadcrumbsWalkFromTheRoot`, `filesOpenFoldersFilterAndPreview`)
- [x] Line-numbered Git diffs in the inspector (M2; `diffLinesCarryNumbersAndWorkingHunkIndexes`)
- [x] Diff review: revert a hunk, revert a file, stage a file (M2; the backend test "reverts a hunk, reverts a file and stages a file", `reviewActionsCallTheBackendThenRefresh`)
- [x] Worktree conversations, and merge or remove in the inspector (M2; the backend test "merges and removes only Muse worktrees, and keeps a busy one", `aWorktreeConversationFollowsItsWorktree`, the worktree check in `npm run test:integration`)
- [x] Activity inspector for internal reminders and hooks (M2; `activityKeepsInternalAndToolItemsWithElectronsLabels`)
- [x] Settings → Muse Code: executable path, connection status, reconnect (M3; `testSettingsAgainstTheFakeBackend`, `aMuseCodePathIsTrimmedSavedThenReconnects`, `aFailedReconnectKeepsTheNoticeAndShowsInSettings`, `reconnectClearsTheNotice`. The live checks of a bad path and of "Use automatic detection" move to M4)
- [x] Settings → MCP servers, including OAuth sign-in through `muse mcp login` (M3; the backend tests "adds, turns off and removes one entry, keeping every other key" and "signs in to remote servers only, through Terminal", `tests/unit/headless-terminal.test.ts`, `turningOnRemovingAndSigningInSendTheirRequests`, `testSettingsAgainstTheFakeBackend`. The live check that Terminal opens moves to M4)
- [x] Settings → Bridges: folder bridge and MCP bridge (M3; `tests/unit/headless-bridges.test.ts`, with "serves the real MCP bridge only with the token", the backend tests "restarts a running MCP bridge with a new token" and "stops both bridges on the quit path", `theKeychainKeepsAndReplacesTheToken`, `aNewTokenGoesToTheStoreAndShowsOnce`, `testSettingsAgainstTheFakeBackend`. The live checks with `curl`, the bridge folder and a relaunch move to M4)
- [ ] Appearance: Muse and Moonlight themes, text size, reduced motion (M3. Built. `themesKeepOnlyMuseAndMoonlight`, `palettesHoldSixDigitHexValues`, `textSizesMatchTheReadingSizes` and `testSettingsAgainstTheFakeBackend` prove the choices and their saves. No test proves that the window changes, or that Reduce motion stops the animations. The live run in M4 does)
- [ ] Completion notifications (M3. Built. `aNoticePostsOnlyForABackgroundTurnThatEnded`, `aNoticeNamesTheConversation` and `everyTurnThatEndsIsReportedWithItsLastStatus` prove when a notice posts and what it says. The posted notice and its click wait for the live run in M4)
- [ ] ⌘K search, grouped (M4)
- [ ] Pinning and local archiving (M4)
- [ ] Markdown export (M4)
- [ ] Composer commands such as `/clear`, `/voice`, `/model`, `/effort`, `/compact` and `/rename` (M4)
- [ ] `@file` mentions, attachments, and drag-and-drop file context (M4)
- [ ] Voice: microphone button and Option–V, live waveform, transcription into the draft (M4)
- [ ] Open the project in Finder or Terminal, or in the full Muse Code CLI (M4)

## Out of scope

Distribution to other people, bundled Node, notarization, Windows and Linux, and the dropped themes. Sparkle updates stay off until the app has its own feed and signing identity.

## Open questions

- Removing the Electron app is decided at parity, not before.
