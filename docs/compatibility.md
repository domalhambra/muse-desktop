# Compatibility

mMac was tested on macOS 27.2 Apple Silicon with Muse Code 1.4.11 (1.4.11-R6667.1) and the official TypeScript SDK 1.4.7, with the echo provider: M1 on October 21, 2026, and M2 to M4a on October 22, 2026. It has not run against a real model yet. The core's extensions (diff review, worktrees, MCP servers, bridges) were first tested on October 20, 2026, with Muse Code 1.4.11. Upstream's Electron app was verified with Muse Code 1.4.7 on October 12, 2026.

mMac needs macOS 15 or newer, Node.js 22.12 or newer on the login shell's PATH, and the Muse Session Protocol that `muse serve` exposes. The backend checks the protocol fingerprint when it connects, and a mismatch shows in the connection status. A match is not proof that every capability is compatible. Run the integration and headless checks after you update the CLI or the SDK.

## Supported workflows

Automatic CLI discovery with the login-shell environment; a custom CLI path; session listing, reading, resuming, renaming and Markdown export; ⌘K search; local pins and archives; streamed messages and tool items; reasoning summaries; server-provided approval choices; agent questions; stop, queue and steer; model selection and reasoning effort; text and image attachments by the paperclip, a drop or a paste; `@` mentions of project files; composer commands; project file previews; Git status and diffs; diff review; worktree conversations; Finder, Terminal and full CLI handoff from the inspector; permission modes (Allow all, Prompt unmatched, On request, Deny unmatched); the `!` shell escape in the composer; side chat; the context gauge; the Tasks, Agents and Preview inspector tabs; the file context menu; Desktop's session shortcuts (⌘⇧] and ⌘⇧[, Esc to stop, ⌘;, ⌘/); the Muse and Moonlight themes, text size, Reduce motion and completion notifications; microphone recording and CLI voice transcription; MCP servers; both bridges.

## Practical limits

- A live session owned by a separate CLI process may be leased. Finish or close it there before you resume it in mMac. mMac shows the CLI's rejection and does not force ownership.
- Account setup, plugin and skill administration, advanced permission-profile editing, goal and workflow administration, and CLI-specific slash commands stay CLI tasks. Click **Muse Code** in the project inspector for the full interactive CLI. The composer handles /clear, /new, /voice, /model, /effort, /compact, /rename, /stop, /settings and /help. Other slash commands explain the CLI handoff, and are not sent as model messages.
- Existing session lists are paged automatically. If the CLI omits inline transcript history, the backend reads and folds the durable view pages. Muse Code 1.4.7 can reject live subscriptions to unloaded sessions. These stay readable as saved history, and are resumed only for a mutating action.
- Tool output preview is limited to 1 MB. File preview is limited to 512 KB. Attachments allow five files, 2 MB per file, 200 KB per text file, and about 4 MB per message including encoded image data.
- Images in model Markdown never load. They show as `[Image: <alt>]`. Web links open in your default browser after a click.
- Unsent drafts survive conversation switching within the running app, but not quitting. Attachment chips belong to the composer and are temporary.
- Model availability and reasoning support come from the installed CLI and provider. Unsupported combinations produce the CLI's error.
- mMac has no updater. Rebuild it from the checkout to update it. Your CLI updates on its own.
- Markdown footnotes show as superscript numbers, with the notes in a numbered list at the end. mMac rewrites them before parsing, because swift-markdown does not parse them. A definition must start a line; indented lines continue it.

## Extensions

- Worktree conversations use Muse's experimental MSP surface (`'session/start'` `worktree`, `'worktree/list'`). When the CLI does not grant it, the worktree toggle is hidden and the inspector lists no worktrees. mMac records the project in Muse's `~/.config/muse/trust.json` before a worktree session starts, from the window or a bridge, the same record the TUI writes when you trust a folder.
- Merge refuses a worktree with uncommitted changes, and aborts a merge with conflicts so the main checkout stays unchanged. Remove keeps the worktree's branch.
- MCP server changes take effect when mMac reconnects to Muse. The pane offers **Reconnect** and never reconnects during your work on its own. Remote servers that need OAuth sign in through `muse mcp login`, which opens in Terminal.
- The diff view shows hunk revert buttons for working-tree changes only. Staged changes have none.

## Session controls (M5a)

- The host asks Muse for the `userShell` capability at the handshake (`requestedCapabilities`), beside `sessionListStream`. Without the grant, `'session/userShell'` fails and mMac shows Muse's error.
- `'session/setApprovalMode'` takes one of Muse's four modes and returns the mode in effect, which can differ from the one asked for. It applies to Muse's next action; an action already awaiting approval is not re-decided.
- `'session/sideChat'` returns the new side session's resume envelope. The side session's kind is `sideChat`; it never appears in the sidebar or ⌘K.
- The host folds `'session/approvalModeChanged'`, `'session/contextUsage'` (`usedTokens`, `windowTokens`, `pressure`) and `'session/todoListChanged'` (the whole list, replaced each time). A reopened conversation shows context and todos after the next event.
- Subagent items carry `childSessionId`, `controlStatus` and `usage`; shell items carry `exitCode`; side chat items carry `sideSessionId`. All are optional: an older CLI's items still decode.

## Voice

The installed CLI must provide `muse voice transcribe <FILE>`. Option–V or the microphone button starts and stops recording, and Escape cancels. mMac records with AVAudioEngine and writes mono 16 kHz 16-bit PCM WAV to a private temporary file. The backend checks the file, passes the audio to that command with the discovered CLI environment, and deletes the file. A two-minute limit (the recorder stops at 119 seconds) and a ninety-second transcription timeout keep requests bounded. Audio may be sent to the service configured by Muse Code; this is not offline transcription.

macOS asks for microphone access on first use. `mac/project.yml` sets `NSMicrophoneUsageDescription`. mMac is not sandboxed and has no hardened runtime, so it needs no audio-input entitlement. mMac is signed ad hoc, so macOS can ask again after a rebuild. Transcription appends to the draft without sending it.

The WAV encoding, the voice states and the backend's calls have unit tests. The real microphone, the permission prompt and a real transcription wait for M4b's live run.

## Runtime dependencies

- cron-parser 5.10.2. Scheduled tasks' custom trigger and next run. A cron parser with tests is more code than the rest of scheduled tasks (parity spec).

## Diagnose a connection

Check `muse --version` and `muse serve --help` in Terminal. Complete `muse login` there if authentication is needed. Choose the executable in **Settings → Muse Code** if discovery fails. Login-shell discovery has a six-second timeout, then falls back to normal installation paths. CLI initialization has a fifteen-second timeout.

The checks can use an explicit installation:

```sh
MUSE_BIN=/absolute/path/to/muse npm run test:integration
MUSE_BIN=/absolute/path/to/muse npm run test:headless
```

See the [official SDK guide](https://meta-models.github.io/muse-code-sdk/next/guides/quickstart/) for the underlying protocol.
