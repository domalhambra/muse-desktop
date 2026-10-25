# Muse Desktop · Unofficial · Dom's fork, with mMac

**Unofficial community software. Not affiliated with, endorsed by, sponsored by, or supported by Meta.** Muse Code is a separate product of Meta. This repository holds a desktop app for the Muse Code CLI, not the CLI or a Meta account.

This is Dom Alhambra's fork of Muse Desktop by [Robert Courson (@robzilla1738)](https://github.com/robzilla1738/muse-desktop). Upstream is an Electron app. This branch's app is **mMac**, a native SwiftUI app for macOS in `mac/`. mMac runs upstream's Node core unchanged, in one plain Node process. Electron's shell left this branch on 2026-10-22. Contributors start at `CLAUDE.md`, and every document is indexed in `docs/README.md`.

## What it does

- Finds your installed `muse`, with your login-shell environment, or uses a path you choose. No API key and no separate account.
- Streams conversations, reasoning summaries, grouped tool activity and stored output, with language-labeled code blocks and one-click copy.
- Opens and resumes CLI sessions, renames them, and finds them with grouped ⌘K search. Pins conversations, archives them in mMac only, and exports them to Markdown.
- Shows the CLI's exact approval choices and agent questions. Cancels, queues follow-ups and steers. Chooses the model and the reasoning effort.
- Opens local projects with Git branch and change badges, previews files, and shows line-numbered diffs in the inspector. Reverts a hunk or a file, or stages a file.
- Starts a conversation in a Git worktree that Muse Code creates under `<project>/.muse/worktrees/`, and merges or removes it from the inspector.
- Handles composer commands such as `/clear`, `/voice`, `/model`, `/effort`, `/compact` and `/rename`. Type `/` for commands or `@` for project files. Attach images and text files with the paperclip, by a drop on the composer, or by a paste.
- Records voice with the microphone button or Option–V, transcribes it with `muse voice transcribe`, and puts the text in the draft. It never sends it on its own.
- Opens the project in Finder, in Terminal, or in the full Muse Code CLI from the inspector.
- Has a native Settings window: the Muse Code path, the MCP servers in Muse Code's own `~/.config/muse/settings.json` with sign-in through `muse mcp login`, the folder and MCP bridges (see [bridges](docs/bridge.md)), the Muse and Moonlight themes, text size, Reduce motion and completion notifications.
- Shows the conversation's tokens and estimated cost in the inspector, and the 5-hour and weekly limits at the bottom of the sidebar, when Muse Code reports them.
- Runs scheduled tasks while it is open: a prompt in a trusted project, hourly, daily, on weekdays, weekly, by hand or on a cron expression (**Settings → Scheduled**).
- Shows a project's pull requests as change cards, with a delivery track and Accept, through the GitHub CLI (`gh`) when it is installed and signed in.
- Imports existing CLI history and finds its project folders. Internal reminders and hooks stay in the Activity inspector.

## What it needs

- macOS 15 or newer.
- Xcode, and XcodeGen (`brew install xcodegen`).
- Node.js 22.12 or newer on your login shell's PATH. mMac runs its backend on it.
- Muse Code with `muse serve`, installed and signed in. See `docs/compatibility.md`.
- For change cards only: the GitHub CLI (`brew install gh`), signed in with `gh auth login`.

mMac is not packaged or signed for other people. It runs from this checkout: it starts its backend with `node --import tsx src/headless/server.ts` in the checkout it was built from.

## Build and run

```sh
npm ci
(cd mac && xcodegen generate)
xcodebuild build -project mac/mMac.xcodeproj -scheme mMac -configuration Debug -derivedDataPath .cache/mmac -destination 'platform=macOS'
open .cache/mmac/Build/Products/Debug/mMac.app
```

Open a project, confirm its trust prompt, and send a message. Existing conversations and their project folders appear by themselves. If mMac cannot find `muse`, choose it in **Settings → Muse Code**.

## Develop and verify

The gate is "Prove a change" in `docs/changing-things.md`. The integration and headless scripts and the UI tests use the real CLI's echo provider, temporary homes and temporary projects. They need no model API key. Real model calls, your account's permissions and external tools need a signed-in CLI, and the echo tests do not exercise them.

mMac's measured size against the Electron app is in "Size" in `docs/architecture.md`. See also [architecture](docs/architecture.md), [compatibility](docs/compatibility.md) and [contributing](CONTRIBUTING.md).

## Data and permissions

The CLI stays responsible for credentials, model requests, tools, sandboxing and session storage. mMac changes the CLI's configuration in two places only, each on your action: a worktree conversation adds its project to `~/.config/muse/trust.json`, and **Settings → MCP servers** edits the MCP entries in `~/.config/muse/settings.json`. Every other key stays as it was. mMac stores no copy of your credentials and adds no analytics. Model requests still reach the provider configured in Muse Code.

mMac keeps its preferences, recent projects, project trust, pins, archives and scheduled tasks in `~/Library/Application Support/mMac`, and the MCP bridge token in the login Keychain. Voice audio goes only through your installed CLI and its transcription service. The temporary recording is private and deleted after transcription or cancellation, and the text is never sent on its own. Pasted images go to private temporary files, which mMac deletes after the send or the removal. Drafts stay in memory and are not restored after quitting. Archiving only hides a conversation in mMac; it does not delete the CLI session. Pull requests go through your own `gh` and its sign-in; mMac merges one only after you confirm.

## License and artwork

Source code is [MIT licensed](LICENSE). See [NOTICE](NOTICE.md) for the Muse mark and third-party licensing. Trademark rights are separate from the source-code license.
