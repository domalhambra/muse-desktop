# mMac M4a: design

Status: approved. Designed with Dom on 2026-10-22, one section at a time. Dom approved each section. It extends `docs/superpowers/specs/2026-10-21-mac-app-design.md`, which stays the source for the architecture, the messages and the parity checklist.

## Goal

M4a builds the last seven parity features, measures mMac's size against the Electron app, checks parity, and removes Electron's shell when every parity item has passing automated tests.

M4b follows it. M4b holds the proof work: the UI tests, written and run three times, and the live isolated run of M2, M3 and M4a.

## Scope

| In M4a                                                                       | In M4b                                                      |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------- |
| ⌘K search, grouped                                                           | UI tests for every M4a feature, written and run three times |
| Pinning and local archiving                                                  | `mac/scripts/ui-tests.sh 3` on the final code               |
| Markdown export                                                              | The live isolated run: M3's Task 16 list, plus M4a's checks |
| Composer slash commands                                                      | The inspector clipping check in a 900-point window          |
| `@file` mentions, attachments, drag-and-drop and paste                       | Screenshots for Dom                                         |
| Voice input                                                                  |                                                             |
| Open the project in Finder, Terminal or the Muse Code CLI                    |                                                             |
| The size measurement, the parity report, and the removal of Electron's shell |                                                             |

Unit and backend tests stay in M4a. Every task writes its tests first. The M4a gate runs them all.

## Decisions

| Decision                                                                                                                                                                 | Why                                                                                                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| The M1 to M3 pattern: backend methods in `src/headless/`, every rule as pure Swift in MuseKit with unit tests, and thin SwiftUI in `mac/mMac/`                           | One copy of each format and limit, and each rule is testable without the app                                                   |
| No edits under `src/main/`. The backend imports `src/main/voice.ts` unchanged. The attachment code is copied from `src/main/index.ts` into `src/headless/attachments.ts` | `index.ts` is deleted at the end of M4a, so a shared module would be edited only to be orphaned                                |
| Electron's bugs are fixed. Its choices are improved where Dom chose to improve them. Each difference goes in `docs/decisions.md`                                         | Dom's call on 2026-10-22: "Fix bugs and improve choices"                                                                       |
| An unknown `/word` draft still shows "is not handled by Desktop"                                                                                                         | It stops a CLI command such as `/plugins` from reaching the model as a message                                                 |
| Voice runs `muse voice transcribe`, as Electron does. No `SFSpeechRecognizer`                                                                                            | The CLI owns the login and the speech service. mMac stores no key                                                              |
| Large data crosses the wire as a path to a private temp file, never as base64 in a JSON line                                                                             | Pasted images and voice clips can reach several MB. The backend reads and validates the file, as it validates every other path |
| Electron's shell is removed at the end of M4a, before M4b's live run                                                                                                     | Dom's call on 2026-10-22                                                                                                       |

### Bugs fixed

- ⌘K caps the conversations at 25, not the whole list at 30. Actions and Themes always show.
- The Archive and Restore label follows whether the conversation is archived, not the sidebar toggle.
- The export title falls back to the sidebar title (`SessionTitle.of`), which includes the first prompt.
- A voice failure with empty stderr shows "Muse Code could not transcribe this recording. Check your connection and CLI voice setup, then try again." It no longer shows the raw "Command failed: …" text with the temp path.
- Pin and archive toggles read the latest preferences and run one at a time. Two quick toggles can no longer lose the first one.

### Choices improved

- Dropping files on the composer attaches them as chips, with the paperclip's limits. A dropped folder inside the project inserts `@<project-relative path>/`. A dropped folder outside the project shows "Drop files, or a folder inside this project."
- Pasting an image writes it to a private temp file (mode 0600) and attaches it. Pasting files copied in Finder attaches them. Pasting text is unchanged.
- ⌘K leaves out subagent and reminder sessions and lists conversations by last activity, newest first.
- `/help` opens a native Help sheet. It lists the composer commands, the shortcuts (⌘K, ⌥V, ⌘N, ⌘O, ⌘,, ⌥⌘I) and says to use **Muse Code** in the inspector for every other CLI command. mMac has no docs page.
- Sidebar rows get a context menu: Pin or Unpin, Archive or Restore, Rename, Export as Markdown.

### Kept as Electron does it

- Every string, limit and keyboard rule in the three surveys, except where this spec says otherwise. The surveys are `docs/superpowers/plans/2026-10-22-mmac-m4a-survey.md`.
- ⌘K Themes lists only Muse and Moonlight, the two themes mMac keeps.
- A conversation that gets a new message stays archived.

## The features

### ⌘K search

- **MuseKit:** `CommandMenuModel` builds the entries (three actions, conversations, themes), groups them under Actions, Recent conversations and Themes, and filters them. The filter is a case-insensitive substring match (`lowercased().contains`) on `title + " " + subtitle`. The query is not trimmed. Electron's strings are kept verbatim.
- **App:** View › Command Menu (⌘K) opens a sheet. The field takes focus. Up and Down clamp, Return chooses, Esc closes, a hover selects and a click chooses. The empty state reads "No matches. Try a project or conversation name." Choosing a result closes the sheet, then runs `startNew`, `openProject`, Settings, `open(id)` or a theme save.

### Pins and archives

- **Data:** `pinnedSessionIds` and `archivedSessionIds` join `Preferences` and `PreferencesPatch`, with `[]` defaults. The backend's `preferences` method already saves them.
- **Rules:** `SidebarSections.build` takes the pinned ids, the archived ids and the archived-view flag. It keeps a session when its archived state matches the view. It sorts pinned first, then by last activity. Pinned sessions form the Pinned group, also in the archived view.
- **Workspace:** `togglePin(id)` and `toggleArchive(id)` compute the new array from the latest preferences, one toggle at a time. Archiving or restoring the open conversation returns to New conversation. `startNew()` turns the archived view off.
- **UI:**
  - A row shows a pin icon when pinned. A hover pin button reads "Pin conversation" or "Unpin conversation".
  - An Archive toggle sits beside CONVERSATIONS. Its label reads "Show archived conversations" or "Show conversations". The header reads ARCHIVED in the archived view.
  - The archived empty state reads "No archived conversations" and "Archived conversations appear here."
  - The toolbar's ⋯ menu ("Conversation actions") shows when a conversation is open: Rename conversation, Pin or Unpin conversation, Export as Markdown, Archive in Desktop or Restore conversation.
  - Sidebar rows get the context menu above.

### Markdown export

- **Backend:** `export(sessionId, path)` checks the path as `add-project` does and reads the open view (`getView`). It writes Electron's format with mode 0600 and returns the path. The format:
  - `# <title>`, where the title is `name`, then `title`, then the sidebar title, then `Muse conversation`.
  - `Project: <workspaceRoot or None>`.
  - One `## You`, `## Muse` or `## <tool or kind>` section per item. Each body is the first non-empty of `displayText`, `text`, `visibleOutput`, `fallbackText`, `summary` joined by newlines, and `objective`.
  - Parts are joined by a blank line, and the file ends with one newline.
- **App:** an `NSSavePanel` sheet opens on the main window. Its default name is the title with every character outside letters, digits, space, `_` and `-` removed, cut to 80 characters, plus `.md`. Success shows the toast "Conversation exported to Markdown." Cancel does nothing.

### Composer slash commands

- **MuseKit:** `ComposerCommand` holds the ten commands in Electron's order, with their descriptions. It also holds:
  - the menu rule `^/[a-z-]*$` (case-insensitive, on the whole draft) and the prefix filter;
  - the parse rule `^/([a-z-]+)(?:\s+([\s\S]*))?$` on the trimmed draft;
  - the Tab, Enter and Escape rules;
  - every error string.
- **Backend:** `compact(sessionId)` calls `muse.compact`. The toast reads "There is no conversation history to compact yet." for `noop`, else "Muse is compacting this conversation."
- **App:**
  - A popup above the composer shows the commands. While it shows, Tab chooses a row instead of moving focus.
  - A toast surface shows successes for 4 seconds and errors until dismissed.
  - `/rename` with no argument opens the Rename sheet. `/settings` opens Settings. `/help` opens the Help sheet. `/voice` starts or stops voice input.

### `@file`, attachments, drag-and-drop and paste

- **MuseKit:**
  - The mention rule `(?:^|\s)@([^\s@]*)$` runs on the whole draft. It splits the folder from the filter and keeps 12 rows. A file inserts its project-relative path and a space, and a folder inserts its path and `/`. The rows come from the existing `files` call.
  - Attachment chips live in the composer state, beside the draft and not per conversation.
- **Backend:**
  - `attachments(paths)` takes at most 5 paths and checks each file (a regular file under 2 MB). It returns `{id, name, kind, size}`.
  - `remove-attachment(id)` forgets an attachment.
  - `send` accepts at most 5 ids. It builds the parts and display text as Electron does, with the limits of 200 KB per text file and 4 MB per message (raw bytes times 1.4). It forgets the ids only after a successful send.
  - All of Electron's strings are kept.
- **App:**
  - The paperclip ("Attach images or text files") opens a multi-select `NSOpenPanel` sheet titled "Add context to your message".
  - Chips show an icon, the name and a remove button ("Remove <name>").
  - The composer is a drop target.
  - A pasted image goes to a temp file in mMac's own temp folder, and mMac deletes it after the send or the removal.
  - A command with chips shows "Send attachments with a message, or remove them before using a command."

### Voice input

- **Backend:**
  - `voice(path)` reads the WAV, runs `validateVoiceAudio` and `VoiceTranscriber.transcribe`, and deletes the file.
  - `cancel-voice` cancels a transcription. The quit path cancels it too.
  - A failure whose text starts with "Command failed" maps to the general error string.
- **MuseKit:**
  - `VoiceWAV` encodes mono 16 kHz 16-bit PCM WAV as `src/shared/voice.ts` does, with the same limits and errors. Its tests use Electron's test values.
  - `VoiceSession` holds the states (idle, permission, recording, transcribing), the timer, the stop at 119 seconds, and the append rule. The text goes at the end of the draft, after one space when needed, and is never sent.
- **App:**
  - `AVAudioEngine` records the microphone and feeds a level meter.
  - The mic button reads "Voice input (⌥V)", or "Stop recording (⌥V)" while recording.
  - The status pill shows "Opening microphone…", "Listening · M:SS" with five level bars, or "Transcribing with Muse…". Its cancel button reads "Cancel voice input". Esc cancels too.
  - Edit › Voice Input (⌥V) works anywhere in the main window.
  - A refused microphone shows "Microphone access is off. Enable mMac in System Settings → Privacy & Security → Microphone."
  - `NSMicrophoneUsageDescription` goes in `mac/project.yml`: "mMac records your voice only when you start voice input, then uses your Muse Code CLI to transcribe it into a draft."

### Open in Finder, Terminal or Muse Code

- **Backend:**
  - `terminal(project)` opens Terminal on `cd '<project>'`.
  - `cli-terminal(project)` opens it on `cd '<project>' && '<muse path>'`.
  - Both check the project first (`knownProject`) and reuse `src/headless/terminal.ts`, which gets a folder-only command helper.
- **App:** the inspector's footer shows three buttons: Finder, Terminal and Muse Code. Finder opens the folder with `NSWorkspace`. Errors show as error toasts.

## Size measurement

`mac/scripts/measure-size.sh` measures both apps and prints the method beside each number.

- **Disk:** `du -sk` of:
  - the Release `mMac.app`, rebuilt first;
  - `/Applications/Muse Desktop.app`;
  - the Node binary mMac finds;
  - the checkout's `src/` and its production `node_modules`.

  mMac's bundle and its runtime dependencies are reported on separate lines.

- **Memory:** the script launches each app with a temporary HOME, MUSE_HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME and ZDOTDIR, `MUSE_DESKTOP_TEST_PROVIDER=echo` and `MUSE_NO_AUTO_UPDATE=1`. It waits 60 seconds on the first screen, then records `footprint` and summed RSS for every process of the app. For mMac that includes the Node backend. `muse serve` is counted on its own line for both. Then the script quits each app and checks that no process is left.
- **When:** after the features are built and before Electron is removed. The installed app in `/Applications` is never changed.
- **Results:** in the main spec's goal and in `docs/architecture.md`, with the date and the macOS version.

## Parity check and Electron removal

- **Parity report:** `docs/superpowers/plans/2026-10-22-mmac-m4a.md` ends with all 27 checklist items. Each item names the passing tests that prove it, and the main spec's checklist is ticked to match.
- **The rule:** if every item has passing automated tests, Electron's shell is removed. Appearance and Completion notifications count on their unit tests, and M4b's live run confirms them on screen. If an item has no passing test, the removal stops and Dom is told.
- **Removed:**
  - `src/renderer/`, `src/preload/`, `src/main/index.ts` and `src/main/updates.ts`;
  - `tests/e2e/` and `playwright.config.ts`;
  - `electron-builder.yml` and `electron.vite.config.ts`;
  - `native/sparkle.mm`, the Sparkle, appcast and notarize scripts in `scripts/`, and `updates/`;
  - the Electron, electron-builder, electron-vite, React, Vite, Playwright and notarize packages, and every npm script that uses them.
- **Kept:** every other `src/main/` module, `src/shared/`, `src/headless/` and their tests.
- **Changed:**
  - `tests/unit/headless-parity.test.ts`, which compares `index.ts` with `server.ts`, becomes a test of the backend's own method list.
  - `npm run build` becomes the typecheck.
  - `CLAUDE.md`, `README.md`, `docs/architecture.md`, `docs/changing-things.md`, `docs/compatibility.md` and `docs/decisions.md` describe mMac as the app.
- **Upstream syncs:** every upstream change to a deleted file becomes a merge conflict. The fix is to keep the deletion and port any core change by hand. `docs/changing-things.md` gets this step.

## Testing

| Layer         | M4a adds                                                                                                                                                                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Backend       | Vitest cases for `compact`, `export` (the exact format), `attachments`, `remove-attachment`, `send` with attachments (every error string), `voice`, `cancel-voice`, `terminal` and `cli-terminal`. The parity test's lists change to match |
| `MuseBackend` | Encoding tests for each new method                                                                                                                                                                                                         |
| `MuseKit`     | Tests for `CommandMenuModel`, `ComposerCommand`, the mention rule, `SidebarSections` with pins and archives, the Workspace toggles, the attachment chips, `VoiceWAV` and `VoiceSession`                                                    |
| The app       | `xcodebuild build-for-testing` succeeds. The UI tests wait for M4b                                                                                                                                                                         |

The M4a gate: `npm run typecheck`, `npm run build`, `npm run format:check`, `npm test`, `npm run test:integration`, `npm run test:headless`, `swift test` for MuseBackend and MuseKit, and `xcodebuild build-for-testing`. Until Electron is removed, the gate also builds the Electron app. `npm run test:e2e` is not run in M4a, and it is deleted with the shell.

## Order

Branch `mac-m4a`, from `extensions`, in the worktree `.cache/worktrees/mac-m4a`. Subagent-driven: one task at a time, each with a spec review, then a quality review.

1. Backend methods and their Swift client calls.
2. MuseKit rules and stores.
3. The app features.
4. The size measurement.
5. The parity report.
6. The removal of Electron's shell.
7. A review of the whole branch.
8. Docs to the repo standard.
9. The gate, then a PR into `extensions`. Dom merges.

## Hard rules

- Never touch `~/.config/muse/`. Every launch uses a temporary HOME, MUSE_HOME, XDG_* and ZDOTDIR, with the echo provider and `MUSE_NO_AUTO_UPDATE=1`.
- Never push to upstream and never open a PR there.
- No edits under `src/main/`, except the two deletions above. `src/renderer/` and `src/preload/` change only by their deletion.
- Never read or write the Keychain item `com.domalhambra.mmac.bridge-token`.
- UI-test screen capture stays off.
