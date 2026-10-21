# Muse Desktop · Unofficial

[![Checks](https://github.com/robzilla1738/muse-desktop/actions/workflows/ci.yml/badge.svg)](https://github.com/robzilla1738/muse-desktop/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/source-MIT-blue)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)](docs/compatibility.md)
[![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-blue)](docs/compatibility.md)
[![Linux](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-blue)](docs/compatibility.md)

**Unofficial community software by [Robert Courson (@robzilla1738)](https://github.com/robzilla1738). Not affiliated with, endorsed by, sponsored by, or supported by Meta.** Muse Code is a separate product of Meta. This repository provides the desktop companion, not the CLI or a Meta account.

A desktop home for Muse Code across macOS, Windows, and Linux. Your installed CLI, existing sign-in, project settings, and saved conversations—with a unified Mac-inspired desktop interface built around the way you work.

![Muse Desktop in the default blue theme](docs/screenshots/muse.png)

**[Download 0.2.0](https://github.com/robzilla1738/muse-desktop/releases/tag/v0.2.0)** — macOS builds are Developer ID signed by Robert Courson and notarized by Apple (Apple Silicon and Intel). Windows (`NSIS` / `ZIP`) and Linux (`AppImage` / `tar.gz`) builds use the same unified interface. CI artifacts are separate, unsigned development builds.

## What it does

- Discovers your existing `muse` installation across macOS, Linux, and Windows, including your login-shell environment and standard installation paths. No separate API key or desktop account.
- Streams real Muse conversations, reasoning summaries, grouped tool activity, and stored output through the official SDK, with language-labeled code blocks and one-click copy.
- Opens and resumes CLI sessions, with naming, grouped `⌘ K` / `Ctrl K` search, pinning, local archiving, and Markdown export.
- Presents the CLI's exact approval choices and agent questions. Supports cancellation, queued follow-ups, and steering.
- Opens local projects with Git branch and working-tree status badges, previews files with breadcrumbs and file-type icons, supports inline `@file` mentions and drag-and-drop file context, and shows line-numbered Git diffs in the project inspector.
- Includes five themes: **Muse**, **Daylight**, **Moonlight**, **Grove**, and **Plush**, plus system appearance matching, text size, reduced motion, and optional completion notifications.
- Preserves the clean, frameless macOS traffic-light window chrome across macOS, Windows, and Linux, with native file pickers, keyboard shortcuts, project trust dialogs, and theme-matched in-app menus.
- Records voice with the microphone button or **Option–V** / **Alt–V** with live waveform metering, transcribes through `muse voice transcribe`, and inserts text into the draft for review.
- Imports existing CLI conversation history and discovers its project folders automatically; internal reminders and hooks stay in the Activity inspector.
- Supports composer commands such as `/clear`, `/voice`, `/model`, `/effort`, `/compact`, and `/rename`; type `/` for commands or `@` for project files.
- Opens your project in Finder / Explorer / Files, your system terminal, or the full Muse Code CLI directly from the project inspector.
- Includes Sparkle 2 updates in packaged macOS builds, with signed feeds and archives. Check manually in **Settings → About**, or opt into daily checks. Installation always requires your action.

<p><img src="docs/screenshots/daylight.png" width="49%" alt="Daylight theme" /> <img src="docs/screenshots/moonlight.png" width="49%" alt="Moonlight theme" /></p>
<p><img src="docs/screenshots/grove.png" width="49%" alt="Grove theme" /> <img src="docs/screenshots/appearance.png" width="49%" alt="Appearance settings" /></p>
<p><img src="docs/screenshots/windows.png" width="49%" alt="Muse Desktop on Windows" /> <img src="docs/screenshots/linux.png" width="49%" alt="Muse Desktop on Linux" /></p>

## Install

| Platform                    | Download                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| macOS (Apple Silicon)       | [Apple Silicon DMG](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-arm64.dmg) · [ZIP](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-arm64.zip)                                                                                                                                                                                                                                                                                      |
| macOS (Intel)               | [Intel DMG](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-x64.dmg) · [ZIP](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-x64.zip)                                                                                                                                                                                                                                                                                                  |
| Windows 10/11 (x64 & ARM64) | [x64 Installer (.exe)](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-win-x64.exe) · [ARM64 Installer (.exe)](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-win-arm64.exe) · [x64 ZIP](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-win-x64.zip) · [ARM64 ZIP](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-win-arm64.zip)                  |
| Linux (x64 & ARM64)         | [x64 AppImage](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-linux-x86_64.AppImage) · [ARM64 AppImage](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-linux-arm64.AppImage) · [x64 tar.gz](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-linux-x64.tar.gz) · [ARM64 tar.gz](https://github.com/robzilla1738/muse-desktop/releases/download/v0.2.0/Muse-Desktop-0.2.0-linux-arm64.tar.gz) |

Requires macOS 13+, Windows 10/11, or Linux, and a separately installed, signed-in Muse Code CLI. Desktop discovers your CLI and existing conversations automatically. Use **Settings → Muse Code** if you need to select a custom executable. The first project you work in requires your trust confirmation.

Check for updates from **Muse Desktop → Check for Updates…** or **Settings → About**. Daily checks are optional. See [release verification and known limits](docs/release-readiness.md) and the [supported CLI workflows](docs/compatibility.md).

## Run locally

Requires macOS 13+, Windows 10/11, or Linux, Node.js 22.12 or newer, and Muse Code with `muse serve` support. Verified with Muse Code **1.4.7** and `@muse-code/sdk` **1.4.7**. The GUI does not bundle or install Muse Code. Packaging macOS builds also requires Apple's Xcode Command Line Tools (`xcode-select --install`) to compile the small Sparkle bridge.

1. Install and sign in to Muse Code using the [official instructions](https://dev.meta.ai/docs/muse-code).
2. Check that `muse --version` works in your terminal.
3. In this repository, run:

```sh
npm ci
npm run dev
```

On macOS, `npm run dev:isolated` keeps development preferences, the bridge token and recent projects in `~/Library/Application Support/muse-desktop-dev`, so a dev build never changes an installed app's data. Set `MUSE_DESKTOP_USER_DATA` to use another folder. It still uses your real Muse Code configuration in `~/.config/muse`.

Open the packaged application when testing a standalone build. Opening the development Electron binary by itself displays Electron’s launcher. Renderer changes reload during development; restart `npm run dev` after changes to the main process or preload bridge.

Open a project, review its trust prompt, and send a message. Existing sessions and their project folders appear automatically. If detection fails, select the executable in **Settings → Muse Code** and reconnect.

## Build for macOS, Windows, and Linux

```sh
# Unsigned macOS app bundle and DMG for your current architecture
npm run package:unsigned
npm run dist:unsigned

# Windows unpacked directory and NSIS / ZIP installers
npm run package:win
npm run dist:win

# Linux unpacked directory and AppImage / tar.gz archives
npm run package:linux
npm run dist:linux
```

Artifacts go in `release/`. Local macOS builds are unsigned and unnotarized; macOS may require an explicit first-open confirmation. See [release instructions](docs/releasing.md) for signed distribution, multi-platform builds, and checksums.

## Develop and verify

```sh
npm run typecheck
npm test
npm run build
npm run test:integration
npm run test:e2e
npm run format:check
```

Integration and desktop tests use the real CLI's **echo provider**, isolated temporary homes, and temporary projects. They do not need a model API key. Set `MUSE_BIN=/absolute/path/to/muse` if needed. Real model inference, your account's permissions, and external tools require an authenticated installation and are not exercised by echo tests.

The first-run setup test also runs without Muse Code: `npx playwright test tests/e2e/setup.spec.ts` after building. Release checks and remaining manual verification are recorded in [release readiness](docs/release-readiness.md).

The app is built with **Electron, React, TypeScript, electron-vite, and the official Muse SDK**. Electron lets the official Node SDK run directly in the main process, while the renderer is sandboxed behind a narrow typed bridge. No web service is required. See [architecture](docs/architecture.md), [compatibility](docs/compatibility.md), and [contributing](CONTRIBUTING.md).

## Data and permissions

The CLI remains responsible for credentials, model requests, tools, sandboxing, and session storage. Desktop does not rewrite CLI settings, store an additional copy of credentials, or add analytics. Model requests still reach the provider configured in Muse Code; “Local project” describes your files, not offline inference.

Desktop stores appearance, recent projects, project trust, pins, and archives in its Electron application-support directory. Voice audio goes only through your installed CLI and its transcription service. Temporary audio is deleted after completion or cancellation; voice text is never sent as a message automatically. Draft text is kept in memory and is not restored after quitting. Archiving only hides a conversation in Desktop; it does not delete the CLI session. Removing Desktop does not remove your CLI or its conversations.

Sparkle stores update preferences in macOS user defaults. Manual checks, or daily checks when enabled, connect to GitHub to retrieve the signed feed. Installing an update downloads its archive from GitHub Releases. System profiling is disabled; no conversations or project files are included in update requests.

## License and artwork

Source code is [MIT licensed](LICENSE). See [NOTICE](NOTICE.md) for the supplied Muse logo, mascot reference, generated artwork, and third-party licensing. Generation prompts are recorded in [docs/image-prompts.json](docs/image-prompts.json) and [docs/plush-image-prompt.json](docs/plush-image-prompt.json). Trademark and reference-image rights are separate from the source-code license.
