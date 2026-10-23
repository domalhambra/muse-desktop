# Changing things

One section per task. Each names the file to edit, the test that judges it, the check that proves it and the spec to read first. The gate for every change is in "Prove a change" at the end.

## Sync with upstream

1. Run `git switch main`.
2. Run `git fetch upstream`.
3. Run `git merge --ff-only upstream/main`. If it refuses, `main` has a commit upstream lacks. Stop and find it. Never commit to `main` directly.
4. Run `git push origin main`.
5. Merge `main` into each open feature branch, and run the gate there.

`main` still holds upstream's Electron app. `extensions` and the branches cut from it do not: M4a deleted Electron's shell (`src/renderer/`, `src/preload/`, `src/main/index.ts`, `src/main/updates.ts`, `tests/e2e/`, the Electron build files and the Sparkle scripts). An upstream change to one of those files stops the merge with a modify/delete conflict. Then:

1. List the files: `git status --porcelain | sed -n 's/^DU //p'`.
2. Keep the deletion: `git rm -- <path>` for each file listed.
3. Read what upstream changed in each one: `git diff HEAD...MERGE_HEAD -- <path>`.
4. Port a core change by hand. A change to a kept `src/main/` module or to `src/shared/` merges by itself. A new or changed IPC channel in `src/main/index.ts` becomes a backend method: follow "To add a backend method" in "Change mMac or its backend". A renderer change becomes a change in `mac/` only if Dom wants it.
5. Finish the merge, and run the gate.

"2026-10-22: mMac M4a" in `docs/decisions.md` names the last commit that has Electron's shell. `git show <that commit>:<path>` reads any deleted file.

## Start a feature

1. Cut the branch from `main`: `git switch -c <name> main`. Cut it from `extensions` only if it builds on the extensions.
2. Commit in the repo's style: `area: summary`, short and lower case, such as `bridge: retry a claimed file once`.
3. Push, then open the PR into the fork with `gh pr create --base main`. The clone's `gh` default is the fork, so the PR cannot land upstream by accident.
4. Dom merges. Do not merge your own PR.

A PR meant for upstream is a separate branch from `main` that carries none of the fork's own files (see `docs/decisions.md`). Open one only when Dom asks.

## Run mMac while developing

Build and open mMac as "Change mMac or its backend" says. mMac keeps its preferences, bridge folder and recent projects in `~/Library/Application Support/mMac`, and its bridge token in the login Keychain. Quit and reopen mMac after a change to `src/`, so it starts a new backend. Rebuild it after a change to `mac/`.

Two features still write to Muse's real config in `~/.config/muse/`. Each changes only its own entries:

- A worktree conversation adds its project to `~/.config/muse/trust.json`.
- Settings → MCP servers edits the `mcpServers` entries in `~/.config/muse/settings.json`.

Back up both files before you test either feature against your real Muse. The test suites never touch them: unit tests use temporary folders, and the integration and headless scripts and the UI tests point `HOME`, `MUSE_HOME` and `XDG_CONFIG_HOME` at a temporary folder.

## Change the Muse connection or a session command

- Edit: `src/main/muse-host.ts`.
- Test: `tests/unit/muse-host.test.ts`. It mocks `@muse-code/sdk`.
- Prove: `npm run test:integration` against the real CLI.
- Read first: `docs/compatibility.md`, and `docs/superpowers/plans/2026-10-20-discovery.md` for the CLI facts.

## Change diff review

- Edit: `src/main/git.ts` for Git, and `src/headless/revert-hunk.ts` for the guarded Revert hunk. In mMac, edit `mac/Packages/MuseKit/Sources/MuseKit/InspectorRules.swift` (`DiffLine`), `mac/Packages/MuseKit/Sources/MuseKit/Inspector.swift` and `mac/mMac/ChangesView.swift`.
- Test: `tests/unit/git-revert.test.ts`, `tests/unit/headless-revert-hunk.test.ts`, `tests/unit/headless-backend.test.ts`, `mac/Packages/MuseKit/Tests/MuseKitTests/InspectorRulesTests.swift` and `mac/Packages/MuseKit/Tests/MuseKitTests/InspectorTests.swift`.
- Prove: `testTheInspectorReviewsChangesAgainstTheFakeBackend` in `mac/mMacUITests/MMacUITests.swift`.

## Change worktree conversations

- Edit: `src/main/worktrees.ts`, `src/main/muse-config.ts` and `src/shared/worktree.ts`. Worktree sessions start in `src/main/muse-host.ts`. In mMac, a worktree conversation starts in `mac/Packages/MuseKit/Sources/MuseKit/Workspace+Actions.swift`, from the toggle in `mac/mMac/ComposerView.swift`. Merge and Remove are in `mac/Packages/MuseKit/Sources/MuseKit/Inspector.swift` and `mac/mMac/ChangesView.swift`.
- Test: `tests/unit/worktrees.test.ts`. For mMac, also `tests/unit/headless-backend.test.ts`, `mac/Packages/MuseKit/Tests/MuseKitTests/WorkspaceInspectorTests.swift` and `mac/Packages/MuseKit/Tests/MuseKitTests/InspectorTests.swift`.
- Prove: the worktree check in `npm run test:integration`, and `testTheInspectorReviewsChangesAgainstTheFakeBackend`.
- Read first: discovery §4. Never write outside `<project>/.muse/worktrees/`. Keep every other key in `~/.config/muse/trust.json`.

## Change the MCP servers pane

- Edit: `src/main/mcp-config.ts`. In mMac, edit `mac/Packages/MuseKit/Sources/MuseKit/SettingsRules.swift` (the form), `mac/Packages/MuseKit/Sources/MuseKit/SettingsModel.swift` and `mac/mMac/McpPane.swift`.
- Test: `tests/unit/mcp-config.test.ts`, `tests/unit/headless-backend.test.ts`, `mac/Packages/MuseKit/Tests/MuseKitTests/SettingsRulesTests.swift` and `mac/Packages/MuseKit/Tests/MuseKitTests/SettingsModelTests.swift`.
- Prove: the MCP check in `npm run test:integration`, which runs `muse mcp login` against the entries the backend writes, and `testSettingsAgainstTheFakeBackend`.
- Read first: discovery §3. Keep `schema_version: 1`. Write `enabled: false`, never `disabled` or `transport`.

## Change a bridge

- Edit: `src/main/agent-api.ts` for jobs, `src/main/bridge-files.ts` for the folder bridge `src/main/bridge-mcp.ts` for the MCP bridge, and `src/headless/bridges.ts` for mMac's start, stop and status.
- Test: `tests/unit/agent-api.test.ts`, `tests/unit/bridge-files.test.ts`, `tests/unit/bridge-mcp.test.ts` and `tests/unit/headless-bridges.test.ts`.
- Prove: the bridge check in `npm run test:integration`, and `npm run test:headless`.
- Read first: `docs/bridge.md`. Update it in the same change when a request field or a tool changes.

## Change mMac or its backend

- Edit: `src/headless/backend.ts` for a backend method (the process itself is `src/headless/server.ts`), `src/headless/wire.ts` for a message shape, `mac/Packages/MuseBackend/` for the Swift client, `mac/Packages/MuseKit/` for logic (Markdown, the transcript and sidebar rules, the `Workspace` store), and `mac/mMac/` for views. The inspector's rules (diff rows, file kinds, breadcrumbs, change labels, Git badges and activity rows) are in `mac/Packages/MuseKit/Sources/MuseKit/InspectorRules.swift`. Its store is `mac/Packages/MuseKit/Sources/MuseKit/Inspector.swift`. `src/headless/login-env.sh` answers `discoverCli`'s login-shell read from the environment mMac passed. `src/headless/server.ts` points `SHELL` at it when `MMAC_LOGIN_SHELL` is set, and `src/headless/login-env.ts` checks that it is there. Keep it executable. The Settings window's backend parts are `src/headless/bridges.ts` (both bridges), `src/headless/terminal.ts` (Terminal for `muse mcp login`) and `src/headless/revert-hunk.ts` (the guarded Revert hunk). Its rules are in `mac/Packages/MuseKit/Sources/MuseKit/SettingsRules.swift`, its store is `mac/Packages/MuseKit/Sources/MuseKit/SettingsModel.swift`, and the token store is `mac/Packages/MuseKit/Sources/MuseKit/BridgeTokenStore.swift`. Its panes are `mac/mMac/SettingsView.swift` and the four pane files beside it.
- Test: `tests/unit/headless-backend.test.ts`, `tests/unit/headless-wire.test.ts`, `tests/unit/headless-parity.test.ts`, `tests/unit/headless-login-env.test.ts`, `tests/unit/headless-bridges.test.ts`, `tests/unit/headless-terminal.test.ts`, `tests/unit/headless-revert-hunk.test.ts`, `swift test` for both packages (`mac/Packages/MuseBackend/Tests/` and `mac/Packages/MuseKit/Tests/`), and the UI tests in `mac/mMacUITests/`.
- Prove: `npm run test:headless`, both `swift test` runs and the `xcodebuild test` run in "Prove a change".
- Read first: `docs/superpowers/specs/2026-10-21-mac-app-design.md`.

Electron's exact strings, call shapes and edge cases are in `docs/superpowers/plans/2026-10-21-mmac-m1-electron-survey.md` and, for the M4a features, `docs/superpowers/plans/2026-10-22-mmac-m4a-survey.md`. Match them unless `docs/decisions.md` records a difference.

To add a backend method:

1. Register it with `method('name', …)` in `src/headless/backend.ts`, with zod checks on every argument.
2. Add a test in `tests/unit/headless-backend.test.ts` with the fake `MuseHost`.
3. Add its name to `expected` in `tests/unit/headless-parity.test.ts`.
4. Add its typed call to `mac/Packages/MuseBackend/Sources/MuseBackend/Methods.swift`, with an encoding test in `mac/Packages/MuseBackend/Tests/MuseBackendTests/`. The parity test fails until the method's name appears in `MuseBackend`.

When a message shape changes, raise `HEADLESS_PROTOCOL` in `src/headless/wire.ts` and `backendProtocol` in `mac/Packages/MuseBackend/Sources/MuseBackend/Messages.swift` together. The parity test fails when they differ.

The UI tests' fake backend is `mac/Fixtures/fake-backend.mjs`. Keep its `protocol` equal to `HEADLESS_PROTOCOL`, and add to it when a UI test needs a backend behaviour the echo CLI cannot produce.

To run mMac from the checkout, you need Xcode, XcodeGen (`brew install xcodegen`), Node 22.12 or newer on your login shell's PATH, and `muse`. Run `npm ci` once.

1. Build mMac with the `xcodebuild test` command in "Prove a change", or with `build` in place of `test`.
2. Run `open .cache/mmac/Build/Products/Debug/mMac.app`.

XcodeGen writes the Xcode project and its Info.plist from `mac/project.yml`. Do not edit or commit them.

mMac starts the backend from the checkout it was built in, with `node --import tsx src/headless/server.ts`. `npm run headless` starts the same backend for a person or a smoke check. mMac does not use it, because npm prints a banner on stdout.

mMac keeps its preferences and its bridge folder in `~/Library/Application Support/mMac`. Set `MMAC_DATA_FOLDER` to use another folder.

### Keep test runs away from Dom's token

mMac keeps the MCP bridge token in the login Keychain, service `com.domalhambra.mmac.bridge-token` (see `docs/bridge.md`). A run of mMac that is not Dom's own use must not read or write that item. Debug builds take two variables. Release builds ignore both.

- `MMAC_KEYCHAIN_SERVICE` names another Keychain service, such as `com.domalhambra.mmac.test`. The account stays `mcp-bridge`.
- `MMAC_TOKEN_STORE=memory` keeps the token in memory, with no Keychain at all. The UI tests set it, because after each ad-hoc rebuild the Keychain asks for the login password.

After a run with a test service, delete its item:

```sh
security delete-generic-password -s com.domalhambra.mmac.test
```

macOS can ask for your login password first. A test must never type it. `security find-generic-password -s <service>`, without `-w`, shows whether the item exists and prints no secret. Never add `-w` in a test: it reads the secret, and macOS asks for the password.

`swift test` for `MuseKit` writes one item with a random service, `com.domalhambra.mmac.test.` and a UUID, and deletes it even when an expectation fails. A run that stops in the middle can leave it. Search for `com.domalhambra.mmac.test` in Keychain Access to find such items.

### Measure mMac's size

Run `mac/scripts/measure-size.sh`. It builds mMac twice: a clean Release build for the disk number, and a Release build with the compilation condition `MMAC_MEASURE` for the memory number. The `MMAC_MEASURE` build keeps the bridge token in memory, keeps its window defaults in the suite `com.domalhambra.mmac.measure` (the script deletes it), and runs the checkout it was built from. So it never reads Dom's Keychain item or changes his defaults. The script checks the build's marker line before it launches it.

Then the script launches that build once, for about 80 seconds, with a temporary home (`HOME`, `CFFIXED_USER_HOME`, `MUSE_HOME`, `XDG_*`, `ZDOTDIR`) and `MMAC_DATA_FOLDER` inside it. `CFFIXED_USER_HOME` moves Application Support but not preferences, which cfprefsd still writes to the real `~/Library/Preferences`, so the build's own suite is what protects Dom's defaults. The Isolation section checks that mMac's real defaults and `~/Library/Application Support/mMac` are unchanged and that no `muse serve` is left. Quit mMac and Muse Desktop first, and leave the window alone while the script runs. It measures Muse Desktop's disk size but never launches it. `--builds-only` builds and checks the markers, and launches nothing.

For Muse Desktop's memory, Dom opens `/Applications/Muse Desktop.app` himself, waits at least 60 seconds, and runs `mac/scripts/measure-size.sh --electron-running`. It finds the app's process tree by its exact executable path, reads its memory, and appends a section to the report. It launches nothing, quits nothing and sends no signal. That number includes Dom's real projects and conversations. The report is `.cache/size/report.txt`. The results and the method are in "Size" in `docs/architecture.md`.

### Run the UI tests

The UI tests drive the real desktop. Before you run them:

- Turn on macOS Automation Mode once: run `automationmodetool enable-automationmode-without-authentication` in Terminal. Leave out `sudo`. With `sudo`, it asks for root's password.
- Unlock the screen, and put no app full-screen in front.
- Expect a prompt after a rebuild. The build is signed ad hoc, and the checkout is under `~/Documents`, so macOS can ask again whether mMac may use the Documents folder. The first run after a rebuild can need you at the keyboard.

The echo test pastes its first message through the general pasteboard, then restores every item the pasteboard held. Do not copy anything while it runs.

Debug builds keep the window's user defaults, such as `inspectorShown`, in the suite that `MMAC_DEFAULTS_SUITE` names. The UI tests set it to `com.domalhambra.mmac.uitests`, and mMac empties it at launch. With the variable set, mMac also turns off window restoration and AppKit's frame autosave for both windows and the sidebar split (`mac/mMac/WindowStateGuard.swift`). Your own mMac defaults stay unchanged. AppKit's open panel still writes a few keys of its own (see `docs/decisions.md`, 2026-10-22). Every UI-test launch also sets `MMAC_TOKEN_STORE=memory`, `-ApplePersistenceIgnoreState YES` and `-NSQuitAlwaysKeepsWindows NO`.

To run the UI tests several times and check the real defaults, run `mac/scripts/ui-tests.sh` with the number of runs, such as `mac/scripts/ui-tests.sh 3`. The default is 3. The script runs each pass under `caffeinate` with a 15-minute limit, stops at the first failed run, and compares the `com.domalhambra.mmac` defaults before and after. It only reads that domain. Its logs go to the `ui-tests` folder in `.cache/`. Warning: on a timeout or Ctrl-C, it stops every mMac built in the `mmac` folder in `.cache/`, a test's or not, and the test runner and the fake backend. Quit your own build from that folder before you run the script.

The scheme keeps screen capture off (`captureScreenshotsAutomatically: false` in `mac/project.yml`). Keep it off: a recording captures whatever else is on the screen.

Every launch the UI tests make points `HOME`, `MUSE_HOME` and `XDG_*` at a temporary folder. Under that `HOME`, mMac finds Node through `/etc/paths`, which the login shell still reads, or through the fallback paths in `mac/Packages/MuseBackend/Sources/MuseBackend/Launcher.swift`. A Node that only nvm or fnm puts on your PATH is not found.

## Update Muse Code or the SDK

1. Update the CLI, or the pinned `@muse-code/sdk` in `package.json`.
2. Run the gate below, integration and headless included.
3. Record the version and the date in `docs/compatibility.md`.

## Record a decision

Add a row to `docs/decisions.md` under today's date: the decision, why and the source. A reversed decision stays in place, marked superseded. A decision that constrains more than this repo also goes in the `plateworks-session-log` repo's `decisions.md`.

## Change the docs

Every Markdown file under `docs/` needs a row in `docs/README.md`. Quote repo paths in backticks from the repo root. `npm test` runs `tests/unit/docs.test.ts`, which runs `scripts/docs_check.py`. That script is vendored. Never edit it here: change the canonical copy in the workspace, then copy it over.

## Prove a change

Run all of these, in this order.

```sh
npm run typecheck
npm test
npm run format:check
MUSE_BIN="$(command -v muse)" npm run test:integration
MUSE_BIN="$(command -v muse)" npm run test:headless
swift test --package-path mac/Packages/MuseBackend --scratch-path .cache/swift
swift test --package-path mac/Packages/MuseKit --scratch-path .cache/swift-kit
(cd mac && xcodegen generate) && TEST_RUNNER_MUSE_BIN="$(command -v muse)" xcodebuild test -project mac/mMac.xcodeproj -scheme mMac -configuration Debug -derivedDataPath .cache/mmac -destination 'platform=macOS' -collect-test-diagnostics never
```

`npm run build` runs the typecheck too. It stays for old habits, and the gate does not repeat it.

`xcodebuild test` builds the app and runs the UI tests. It needs macOS Automation Mode, an unlocked screen and no full-screen app in front. See "Run the UI tests" above. A session that must not open windows runs `xcodebuild build-for-testing` in its place, and says so.

Only the last command needs Xcode and XcodeGen. `swift test` needs only the Swift toolchain. All three write their build output to the gitignored .cache folder at the repo root.
