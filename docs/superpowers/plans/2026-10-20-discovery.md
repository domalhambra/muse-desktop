# Extensions plan: Phase 0 discovery

Recorded 2026-10-20 in a Linux cloud container (Node 22.22.0, npm 10.9.4) against upstream `main` at `874f98e`. Companion to `2026-10-20-extensions.md`.

## Baseline

| Check                          | Result                                           |
| ------------------------------ | ------------------------------------------------ |
| `npm ci`                       | ok                                               |
| `npm run typecheck`            | clean                                            |
| `npm test`                     | 4 files, 18 tests pass                           |
| `npm run build`                | ok (one chunk-size warning, pre-existing)        |
| `npm run format:check`         | clean                                            |
| `npm run test:integration`     | 4 PASS lines against the real CLI, echo provider |
| `xvfb-run -a npm run test:e2e` | 12/12 pass                                       |

Muse Code installs on Linux with `curl -fsSL https://dev.meta.ai/install.sh | sh`. It puts a launcher at `~/.local/bin/muse` and the binary beside it as `muse-bin-<version>`. Installed version: **Muse Code 1.4.11 (1.4.11-R6667.1)**, newer than the 1.4.7 the README names. No login is needed for the echo provider, so integration and e2e tests both run in the cloud.

## 1. Transcript item kinds

From `@muse-code/sdk` 1.4.7, `msp.d.ts`:

```ts
type ItemKind =
  | 'userMessage'
  | 'agentMessage'
  | 'reasoning'
  | 'toolCall'
  | 'userShell'
  | 'subagent'
  | 'workflow'
  | 'reminderChild'
  | 'compaction'
  | 'hookRun'
  | 'sideChat'
  | 'webSearch'
  | (string & {})
```

**Plan correction:** assistant text is `agentMessage`, not `assistantMessage`. The app already uses `agentMessage` in `Transcript.tsx`, `Inspector.tsx` and the export code in `main/index.ts`. Use `KIND.assistant = 'agentMessage'` in Phase 4 and in the AgentApi test fixtures.

## 2. MSP methods

The SDK's stable surface (70 methods) has **no** MCP or settings methods. The experimental surface (96 methods) adds, among others:

- `mcpServer/list`, `mcpServer/oauthLogin`, `mcpServer/oauthLoginCancel`, `mcpServer/oauthLogout`
- `settings/read`, `settings/readSchema`, `settings/writeValue`, `settings/writeMany`
- `worktree/list`, plus a `worktree` param on `session/start`

Experimental opt-in is `capabilities: { experimentalApi: true }` inside `initialize` (not a top-level field). The answer echoes `experimentalApi: true` when granted. Without it, each call fails with `experimentalRequired`.

Probed with the real CLI:

- `settings/writeValue` takes only string, boolean or null values, and `settings/readSchema` exposes nine scalar keys (model, provider, reasoning_effort, and similar). **It cannot write MCP server entries.**
- `mcpServer/list` returned `{"servers": []}` every time, with and without a `sessionId`, even with four valid entries in settings.json that `muse mcp login` resolves. It is not reliable in 1.4.11.

**Decision for Phase 3:** keep the file-based variant. Optionally show `mcpServer/list` OAuth state later, once it returns rows.

## 3. MCP server configuration

| Fact               | Value                                                                                                                                                                         |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| File               | `${XDG_CONFIG_HOME:-$HOME/.config}/muse/settings.json` (on macOS too: `~/.config/muse/settings.json`)                                                                         |
| Required top level | `"schema_version": 1`. If it is missing, `muse serve` refuses to start ("malformed settings file")                                                                            |
| MCP key            | `mcpServers`, an object keyed by server name. `mcp_servers` is also accepted as an alias                                                                                      |
| stdio entry        | `{ "command": "npx", "args": [...], "env": {...} }`                                                                                                                           |
| remote entry       | `{ "url": "https://...", "headers": {...} }`, optional `"type": "http"`                                                                                                       |
| Disabled           | `"enabled": false`. `muse mcp login` then says "MCP server `b` is disabled; enable it under mcpServers first". `"disabled": true` is ignored                                  |
| Rejected           | `"transport": "streamableHttp"` in settings.json. The CLI reports "no MCP server named `b` is configured". That spelling is valid only in `session/start` `config.mcpServers` |
| Sibling files      | `auth.json` (credentials) and `trust.json` (workspace trust) in the same folder                                                                                               |

Method used: `muse mcp login <name> --headless` as a resolver against throwaway `XDG_CONFIG_HOME` folders, one per shape.

**Plan corrections for Task 3.1:**

- `writeRaw` must keep or add `schema_version: 1`. A new file written without it would break `muse serve`.
- `setServerEnabled` writes `enabled: false` and deletes the key to enable. Do not write `disabled`. `fromEntry` should still treat `disabled: true` as disabled when reading, for files edited by hand.
- `toEntry` never writes a `transport` field.
- Config path in `main/index.ts`: `join(process.env.XDG_CONFIG_HOME || join(homedir(), '.config'), 'muse', 'settings.json')`. Note that `cli.ts` builds the CLI environment from the login shell, so prefer `XDG_CONFIG_HOME` from that environment when it is set.

## 4. Worktrees

`muse serve --trust-workspace` accepts any directory as `workspaceRoot`, including a Git worktree made with plain `git worktree add`. A session started in `project/.muse-worktrees/manual` came back with that path as `workspaceRoot`, and a turn started normally. **Open question 2 is answered: no extra flag per worktree.**

The CLI also has **native per-session worktrees**:

- `session/start` with `worktree: { mode: 'create', baseRef?: string }` (experimental) creates `project/.muse/worktrees/<yyyymmdd>-<4 hex>` on branch `muse/session-<sessionId>`, and appends `/.muse/worktrees/` to `.git/info/exclude` itself.
- `worktree: { mode: 'existing', path }` attaches a caller-made worktree.
- The returned session carries `worktree: { path, origin: 'created' | 'attached' }`.
- `worktree/list { workspaceRoot }` returns `{ path, branch, isMain, sessionIds }` for every worktree, so the UI can warn when two sessions share one.
- The CLI's own `--worktree` flag uses the same layout.

Both need the repository recorded as trusted in Muse's `trust.json`. `--trust-workspace` alone is not enough; without the record the CLI answers `workspaceNotTrusted`: "worktree create, attach, and list require a trusted repository". The trust file format, captured by answering the TUI prompt once:

```json
{ "schema_version": 1, "projects": { "/abs/path": { "decision": "trusted" } } }
```

**Recommendation for Phase 2:** use the CLI's native worktrees instead of a separate `.muse-worktrees` layout. Turn on `experimentalApi` in `MuseHost`'s `initialize`, pass `worktree: { mode: 'create' }` from `create()`, and use `worktree/list` for the inspector panel. Keep a small `worktrees.ts` only for what the CLI lacks: merge-back and remove (`git merge --no-edit muse/session-…`, `git worktree remove`), limited to paths under `.muse/worktrees/`. This keeps worktrees made from Desktop and from the TUI in one place, and the CLI owns naming and exclude entries.

What that costs:

- Desktop must record trust in `trust.json` when the user trusts a project. The file is shared with the CLI, so writes must keep other keys and use the same atomic rename as `writeRaw`. The CLI also takes a `.trust.json.lock`; Desktop should write only when no CLI turn is active, or accept a small race.
- Experimental methods can change between CLI versions. Gate the feature on `initializeResult.experimentalApi === true`, and fall back to plain `git worktree add` under `.muse/worktrees/` with `mode: 'existing'` if `session/start` rejects the param.

**Open question 1 is answered: yes, `trustProject` opens a native dialog** (`dialog.showMessageBox`, `index.ts` ~167). The silent shortcut for worktree paths under a trusted parent is needed if Desktop records worktree paths itself. With the native approach, sessions report the worktree as `workspaceRoot`, so `sessionProject()` and `knownProject()` need that same parent-path rule.

## 5. Session status during a turn

Raw notification order after `turn/start` on the echo provider: `session/branchChanged`, `session/statusChanged {status: "running"}`, `turn/started`, `item/completed (userMessage)`, then items and `turn/completed`. `MuseHost` debounces view emits by 32 ms, so these usually coalesce into one `running` view. A view scheduled before `send()` can still fire with `idle` after the job exists.

**Plan correction for Task 4.2:** the `sawRunning` flag is required, not optional. Mark a job `done` only after a `running` view has been seen for it.

## 6. New dependencies

| Package                     | Latest | Notes                                                                                                    |
| --------------------------- | ------ | -------------------------------------------------------------------------------------------------------- |
| `@modelcontextprotocol/sdk` | 1.32.1 | Peer `zod ^3.25 \|\| ^4.0`, which matches the repo's zod 4.6.7. Peer `@cfworker/json-schema` is optional |
| `chokidar`                  | 6.0.0  | `engines.node >= 22.22`, above the repo's stated 22.12 floor                                             |

**Plan correction for Task 4.3:** pin `chokidar@^5` (Node >= 20.19), or use `node:fs.watch` because the inbox watch is depth 0. `chokidar@latest` would raise the Node floor. Recommendation: `chokidar@^5`.

The MCP SDK's streamable HTTP server API is still to be read from its README in Phase 5, as the plan says.

## Not settled here

- Whether Muse for Mac can reach `127.0.0.1` (open question 6). Only Dom can test this.
- Real-model behaviour (approvals with a real provider, tool-call items). The echo provider produces no tool calls or approvals.

## Implementation notes: where the build differs from the plan

The plan was attached to the kickoff message and is not committed in this repository. This section records each place where the build differs from it. The guiding rule from Dom on 2026-10-20: expose Muse's built-in features as much as possible.

### Phase 1: diff review

- `revertFile` uses `git restore --source=HEAD --staged --worktree`. A newly added file (`A`) is unstaged and deleted. An untracked directory is refused, never deleted.
- `getRawDiff` and `stageFile` check containment lexically. `containedFile` resolves the real path and fails on deleted files, which still need diffs and hunk reverts.
- `revertHunk` writes the patch into a private temporary folder and runs `git apply --reverse --recount`. `--unidiff-zero` is left out.
- Hunk numbering lives in `parseDiffLines` and counts only the `Working changes` section. A unit test covers it.
- Revert, stage and hunk buttons are disabled while a turn is running.
- Found and fixed a pre-existing bug: every diff line rendered on one row, because each row was an `inline-block` with its `<br>` inside. Separate commit.

### Phase 2: worktrees

- Uses Muse's native worktrees (`session/start` `worktree: { mode: 'create' }` and `worktree/list`) instead of a `.muse-worktrees` module. Muse names the folder (`.muse/worktrees/<yyyymmdd>-<hex>`) and the branch (`muse/session-<id>`), so the composer has a toggle and no name field.
- `worktrees.ts` keeps only merge and remove. Merge refuses uncommitted worktree changes and aborts on conflicts. Remove keeps the branch.
- `MuseHost.create` writes the project into Muse's `trust.json` before every worktree session, so window and bridge requests both work. The fact-check pass found that the first version did this in the window handler only, which broke bridge worktree jobs. The integration script proves that the CLI reads a record written after the host started, and runs a bridge worktree job in a repository with no prior record.
- Worktree paths are known and trusted through their parent project. Opening a worktree session records the parent in recent projects, not the worktree. The sidebar groups worktree sessions under their project with a `worktree` chip.

### Phase 3: MCP servers

- `mcpServer/list` returns no rows from `muse serve` 1.4.11 even with valid entries, and `mcpServer/oauthLogin` answers "no such MCP server in the host population". The tab therefore reads and writes `settings.json`, and OAuth sign-in runs `muse mcp login <name>` in Terminal.
- Env values and headers never reach the renderer. The tab shows their names only.
- The integration script checks that `muse mcp login` resolves the entries Desktop writes and honors `enabled: false`.

### Phase 4: AgentApi and the folder bridge

- `KIND.assistant` is `agentMessage`. The `sawRunning` guard is in place and tested.
- AgentApi also exposes `userInput/answer`, `turn/cancel`, `model/list` and the worktree option. A session has one active job at a time. A job's transcript and reply hold only the items its own turn produced.
- `AgentPolicy.resolveProject` replaces `isTrusted`. It requires a project Desktop knows (recent) and trusts, and it also applies to a continued session's folder.
- The folder bridge uses `decisions/` instead of `approvals/`: one file approves, answers or cancels. Requests move to `inbox/processed/` instead of hidden `.processed` files. Files are claimed (moved) as soon as they are read, and chokidar `change` events count as new files, because chokidar reports a quick delete-and-recreate as a change.
- `chokidar` is pinned to 5.0.0 and `@modelcontextprotocol/sdk` to 1.32.1. Both installs used npm 11 so the lockfile keeps upstream's `libc` fields.
- The bridge token is not a preference. It lives in `bridge-token` in the app data folder, encrypted with `safeStorage` when available.

### Phase 5: MCP bridge

- Tools use `registerTool`. Added `list_sessions`, `list_models`, `answer` and `cancel`. `ask_muse` and `get_job` take `wait_seconds` (up to 120).
- `handleRequest(req, res)` reads the body itself in SDK 1.32.1. The SDK's DNS-rebinding options are deprecated, so Host is not checked. The bearer token, compared in constant time, protects every request. This keeps Tailscale Serve working.
- A new token restarts a running bridge, so the old token stops working at once.

### Docs

- Tasks 4.5 and 5.3 became one commit after Phase 5, so `docs/bridge.md` covers both bridges.

### Verification

On Linux with Muse Code 1.4.11 and the echo provider: typecheck, 80 unit tests, the integration script (8 checks), 17 Playwright tests under `xvfb-run`, build and format check all pass. macOS, a real model, packaging and the Muse app's reach to `127.0.0.1` are not verified.

## Rename, found 2026-10-21 while building mMac M1

- `session/list` can omit a live session's `name` just after a rename. A fresh backend's list has it, along with `title` and `firstUserPrompt`. The pushed `session` event and `open` carry the name.
- The CLI trims the name and lowercases ASCII A-Z only. " mMac check " becomes "mmac check", and "Hello WORLD Äb-Cd_9 ÉCOLE" becomes "hello world Äb-cd_9 École". Non-ASCII capitals stay as typed.
