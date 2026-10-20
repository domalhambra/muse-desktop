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
