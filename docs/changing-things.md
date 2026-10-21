# Changing things

One section per task. Each names the file to edit, the test that judges it, the check that proves it and the spec to read first. The gate for every change is in "Prove a change" at the end.

## Sync with upstream

1. Run `git switch main`.
2. Run `git fetch upstream`.
3. Run `git merge --ff-only upstream/main`. If it refuses, `main` has a commit upstream lacks. Stop and find it. Never commit to `main` directly.
4. Run `git push origin main`.
5. Merge `main` into each open feature branch, and run the gate there.

## Start a feature

1. Cut the branch from `main`: `git switch -c <name> main`. Cut it from `extensions` only if it builds on the extensions.
2. Commit in the repo's style: `area: summary`, short and lower case, such as `bridge: retry a claimed file once`.
3. Push, then open the PR into the fork with `gh pr create --base main`. The clone's `gh` default is the fork, so the PR cannot land upstream by accident.
4. Dom merges. Do not merge your own PR.

A PR meant for upstream is a separate branch from `main` that carries none of the fork's own files (see `docs/decisions.md`). Open one only when Dom asks.

## Run the app while developing

Run `npm run dev:isolated`. It keeps Desktop's preferences, bridge token and recent projects in `~/Library/Application Support/muse-desktop-dev`. Restart it after a change to `src/main/` or `src/preload/`. Renderer changes reload by themselves.

Two features still write to Muse's real config in `~/.config/muse/`. Each changes only its own entries:

- A worktree conversation adds its project to `~/.config/muse/trust.json`.
- Settings → MCP servers edits the `mcpServers` entries in `~/.config/muse/settings.json`.

Back up both files before you test either feature against your real Muse. The test suites never touch them: unit tests use temporary folders, and the integration script and e2e launches point `HOME` and `MUSE_HOME`, and nearly always `XDG_CONFIG_HOME`, at a temporary folder (see `docs/decisions.md`, Rejected and deferred).

## Change the Muse connection or a session command

- Edit: `src/main/muse-host.ts`.
- Test: `tests/unit/muse-host.test.ts`. It mocks `@muse-code/sdk`.
- Prove: `npm run test:integration` against the real CLI.
- Read first: `docs/compatibility.md`, and `docs/superpowers/plans/2026-10-20-discovery.md` for the CLI facts.

## Change diff review

- Edit: `src/main/git.ts` and `src/renderer/src/components/Inspector.tsx`.
- Test: `tests/unit/git-revert.test.ts`.
- Prove: the first test in `tests/e2e/extensions.spec.ts`.

## Change worktree conversations

- Edit: `src/main/worktrees.ts`, `src/main/muse-config.ts` and `src/shared/worktree.ts`. Worktree sessions start in `src/main/muse-host.ts`.
- Test: `tests/unit/worktrees.test.ts`.
- Prove: the worktree check in `npm run test:integration` and the worktree test in `tests/e2e/extensions.spec.ts`.
- Read first: discovery §4. Never write outside `<project>/.muse/worktrees/`. Keep every other key in `~/.config/muse/trust.json`.

## Change the MCP servers tab

- Edit: `src/main/mcp-config.ts` and `src/renderer/src/components/McpSettings.tsx`.
- Test: `tests/unit/mcp-config.test.ts`.
- Prove: the MCP check in `npm run test:integration`, which runs `muse mcp login` against the entries Desktop writes.
- Read first: discovery §3. Keep `schema_version: 1`. Write `enabled: false`, never `disabled` or `transport`.

## Change a bridge

- Edit: `src/main/agent-api.ts` for jobs, `src/main/bridge-files.ts` for the folder bridge and `src/main/bridge-mcp.ts` for the MCP bridge.
- Test: `tests/unit/agent-api.test.ts`, `tests/unit/bridge-files.test.ts` and `tests/unit/bridge-mcp.test.ts`.
- Prove: the bridge check in `npm run test:integration` and the two bridge tests in `tests/e2e/extensions.spec.ts`.
- Read first: `docs/bridge.md`. Update it in the same change when a request field or a tool changes.

## Change mMac or its backend

- Edit: `src/headless/server.ts` for a backend method, `src/headless/wire.ts` for a message shape, `mac/Packages/MuseBackend/` for the Swift side and `mac/mMac/` for the UI.
- Test: `tests/unit/headless-wire.test.ts`, `tests/unit/headless-parity.test.ts` and the Swift tests in `mac/Packages/MuseBackend/Tests/`, which `swift test` runs.
- Prove: `npm run test:headless`, then the `xcodebuild` build in "Prove a change".
- Read first: `docs/superpowers/specs/2026-10-21-mac-app-design.md`.

To port a method from `src/main/index.ts`:

1. Register it with `method('name', …)` in `src/headless/server.ts`.
2. Delete it from `notYet` in `tests/unit/headless-parity.test.ts`.
3. Add its typed call to `mac/Packages/MuseBackend/Sources/MuseBackend/Methods.swift`.

When a message shape changes, raise `HEADLESS_PROTOCOL` in `src/headless/wire.ts` and `backendProtocol` in `mac/Packages/MuseBackend/Sources/MuseBackend/Messages.swift` together. The parity test fails when they differ.

To run mMac from the checkout, you need Xcode, XcodeGen (`brew install xcodegen`), Node 22.12 or newer on your login shell's PATH, and `muse`. Run `npm ci` once.

1. Build mMac with the last command in "Prove a change".
2. Run `open .cache/mmac/Build/Products/Debug/mMac.app`.

XcodeGen writes the Xcode project and its Info.plist from `mac/project.yml`. Do not edit or commit them.

mMac starts the backend from the checkout it was built in, with `node --import tsx src/headless/server.ts`. `npm run headless` starts the same backend for a person or a smoke check. mMac does not use it, because npm prints a banner on stdout.

mMac keeps its preferences in `~/Library/Application Support/mMac`. Set `MMAC_DATA_FOLDER` to use another folder.

## Add an IPC method

Follow `CONTRIBUTING.md`: add a typed method to `src/shared/protocol.ts` and `src/preload/index.ts`, validate at the boundary, and keep Electron privileges in `src/main/`.

## Update Muse Code or the SDK

1. Update the CLI, or the pinned `@muse-code/sdk` in `package.json`.
2. Run the gate below, integration and e2e included.
3. Record the version and the date in `docs/compatibility.md`.

## Record a decision

Add a row to `docs/decisions.md` under today's date: the decision, why and the source. A reversed decision stays in place, marked superseded. A decision that constrains more than this repo also goes in the `plateworks-session-log` repo's `decisions.md`.

## Change the docs

Every Markdown file under `docs/` needs a row in `docs/README.md`. Quote repo paths in backticks from the repo root. `npm test` runs `tests/unit/docs.test.ts`, which runs `scripts/docs_check.py`. That script is vendored. Never edit it here: change the canonical copy in the workspace, then copy it over.

## Prove a change

Run all of these, in this order. The e2e run rewrites `docs/screenshots/*.png`, so restore them before you commit.

```sh
npm run typecheck
npm test
npm run build
npm run format:check
MUSE_BIN="$(command -v muse)" npm run test:integration
MUSE_BIN="$(command -v muse)" npm run test:headless
MUSE_BIN="$(command -v muse)" npm run test:e2e
git checkout -- docs/screenshots
swift test --package-path mac/Packages/MuseBackend --scratch-path .cache/swift
(cd mac && xcodegen generate) && xcodebuild -project mac/mMac.xcodeproj -scheme mMac -configuration Debug -derivedDataPath .cache/mmac build
```

The first e2e run on a new machine can time out while Playwright downloads Electron. Run it again.

Until PR 4 merges, `tests/unit/bridge-files.test.ts` fails about one run in six. Run `npm test` again.

Only the last command needs Xcode and XcodeGen. `swift test` needs only the Swift toolchain. Both write their build output to the gitignored .cache folder at the repo root.
