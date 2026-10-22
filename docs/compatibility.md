# Compatibility

Verified locally on macOS Apple Silicon with Muse Code **1.4.7 (1.4.7-R6101.1)** and the official TypeScript SDK **1.4.7**, on October 12, 2026.

The extensions (diff review, worktrees, MCP servers, bridges) were developed and tested on Linux x64 with Muse Code **1.4.11 (1.4.11-R6667.1)** and the SDK **1.4.7**, on October 20, 2026: unit, integration and Playwright suites with the echo provider. The same suites passed on macOS 27.2 Apple Silicon with Muse Code 1.4.11 the same day. They have not run against a real model yet.

The GUI requires the Muse Session Protocol exposed by `muse serve`. Protocol fingerprint mismatches are visible in Settings; they are not treated as proof that every capability is compatible. Re-run integration checks after updating the CLI or SDK.

## Supported desktop workflows

Automatic CLI discovery across macOS, Windows, and Linux; custom CLI path; session listing, reading, resuming, renaming and exporting; local pins and archives; streamed messages and tool items; reasoning summaries; server-provided approval choices; agent questions; stop, queue and steer; model selection and reasoning effort; text/image attachments; project file previews; Git status/diff; Finder / Explorer / Files and Terminal handoff; appearance settings and completion notifications; microphone recording and CLI voice transcription; full CLI handoff from the inspector.

## Practical limits

- A live session owned by a separate CLI process may be leased. Finish or close it there before resuming in Desktop. The app shows the CLI's rejection and does not force ownership.
- Account setup, plugin/skill administration, advanced permission-profile editing, goals/workflow administration, and CLI-specific slash commands remain CLI tasks. Open **Project inspector → Muse Code** for the full interactive CLI. The composer handles /clear, /new, /voice, /model, /effort, /compact, /rename, /stop, /settings, and /help. Other slash commands explain the CLI handoff without sending them as model messages.
- Existing session lists are paged automatically. If the CLI omits inline transcript history, Desktop reads and folds the durable view pages. Muse Code 1.4.7 can reject live subscriptions to unloaded sessions; these remain readable as saved history and are resumed only for a mutating action. Reopen a conversation to refresh its saved history.
- Tool output preview is limited to 1 MB. File preview is limited to 512 KB. Attachments allow five files, 2 MB per file, 200 KB per text file, and approximately 4 MB per message including encoded image data.
- Remote images embedded in model Markdown are not fetched. Ordinary web links open in your default browser after a click.
- Unsent drafts survive conversation switching within the running app, but not quitting. Attachment selections belong to the current composer and are temporary.
- Model availability and reasoning support come from the installed CLI and provider. Unsupported combinations produce the CLI's error.
- No automatic application updater is included. Install a newer app bundle to update Desktop. Your CLI updates independently.
- Intel builds are configured but have not been run on Intel hardware. Signed and notarized release verification requires the maintainer's Apple Developer credentials.

Preference updates are independently validated: changing reasoning effort preserves themes, background intensity, the executable path, text size, pins, and archives. With saved conversations, the sidebar uses a compact mascot; short windows switch navigation to labeled icon buttons so conversation history retains scroll space.

## Extensions

- Worktree conversations use Muse's experimental MSP surface (`'session/start'` `worktree`, `'worktree/list'`). When the CLI does not grant it, the worktree toggle is hidden and the inspector lists no worktrees. Desktop records the project in Muse's `~/.config/muse/trust.json` before a worktree session starts, from the window or a bridge, the same record the TUI writes when you trust a folder.
- Merge refuses a worktree with uncommitted changes, and aborts a merge with conflicts so the main checkout stays unchanged. Remove keeps the worktree's branch.
- MCP server changes take effect when Desktop reconnects to Muse. The tab offers **Reconnect** and never reconnects during your work on its own. Remote servers that need OAuth sign in through `muse mcp login`, which opens in Terminal.
- The diff view shows hunk revert buttons for working-tree changes only. Staged changes have none.

## mMac

mMac M1 was tested on macOS 27.2 Apple Silicon with Muse Code 1.4.11 and the echo provider, on October 21, 2026. It has not run against a real model yet.

- Markdown footnotes are drawn as superscript numbers with the notes in a numbered list at the end. mMac rewrites them before parsing, because swift-markdown does not parse them. A definition must start a line; indented lines continue it.
- Images in replies never load. They show as `[Image: <alt>]`, as in Electron.

## Voice

The installed CLI must provide `muse voice transcribe <FILE>`. Option–V or the microphone button starts and stops recording; Escape cancels. Audio is mixed to mono 16 kHz PCM WAV and passed to that command using the discovered CLI environment. Temporary directories and clips have private permissions and are removed on completion, failure, cancellation, or normal app shutdown. A two-minute recording limit and ninety-second transcription timeout keep requests bounded. Audio may be sent to the service configured by Muse Code; this is not offline transcription.

macOS microphone permission is requested on first use. Signed bundles include `NSMicrophoneUsageDescription` and the audio-input entitlement. No camera access is requested. The recording indicator remains visible while capturing; hiding the app cancels input. Transcription appends to the draft without sending it. Switching projects/conversations cancels recording so speech cannot land in a different conversation.

The CLI transcription path was verified using generated speech and the installed authenticated CLI. Recording, cancellation, WAV encoding, and draft insertion are covered using simulated microphone input. Physical microphone capture and macOS permission presentation still need a first-use check on the release candidate.

## Diagnose a connection

Check `muse --version` and `muse serve --help` in Terminal. Complete `muse login` there if authentication is needed. Select the executable in **Settings → Muse Code** if discovery fails. Login-shell discovery has a six-second timeout, then falls back to normal installation paths. CLI initialization has a fifteen-second timeout.

The tests can use an explicit installation:

```sh
MUSE_BIN=/absolute/path/to/muse npm run test:integration
MUSE_BIN=/absolute/path/to/muse npm run test:e2e
```

See the [official SDK guide](https://meta-models.github.io/muse-code-sdk/next/guides/quickstart/) for the underlying protocol.
