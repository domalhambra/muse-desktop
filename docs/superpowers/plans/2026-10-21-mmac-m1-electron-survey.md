# Electron parity survey for mMac M1 (2026-10-21)

Source: a read-only survey of the Electron renderer and main process. File:line references are to the repo at origin/extensions 65ccf27.

I've covered all ten areas below. Sources: `App.tsx`, `Transcript.tsx`, `Composer.tsx`, `Inspector.tsx`, `Select.tsx`, `Settings.tsx`, `Primitives.tsx`, `CommandMenu.tsx`, `WorkspacePages.tsx`, `activity.ts`, `commands.ts`, `preload/index.ts`, `shared/protocol.ts`, `shared/worktree.ts`, `main/index.ts`, `main/muse-host.ts`, `main/cli.ts`, plus the SDK's `ItemStore` (`node_modules/@muse-code/sdk/dist/src/fold/item-store.js`, v1.4.7).

One note on the branch: the checkout is on `mac-app`, not `origin/extensions`. `git diff --stat origin/extensions -- src` comes back empty, so `src/` matches what you asked for.

All paths below are relative to `/Users/dom/Documents/Claude/40-49 Outside Work/42 Muse Desktop/`.

---

## 0. How IPC works, and every AppEvent

**Transport** (`src/preload/index.ts:4-11`)

- Every call is `ipcRenderer.invoke('muse:<channel>', ...args)`.
- The reply is `{ok:true,value}` or `{ok:false,error:string}`. The preload turns a failed reply into `new Error(error)`.
- The main side checks the sender frame, then wraps each handler in try/catch with `messageOf(error)` (`main/index.ts:228-239`).
- `messageOf` replaces Zod errors with `Muse could not read “<field>”. Restart the app to use the latest version, then try again.` (or `Muse could not read this request. Restart the app and try again.` when no field is known) (`muse-host.ts:616-624`).

**Events**

- Main pushes events on `muse:event` (`main/index.ts:112`). The renderer subscribes with `onEvent` (`preload:67-71`).

| AppEvent                           | What the renderer does (`App.tsx:199-219`)                                                                                                                                                                                               |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `{type:'connection',status}`       | `setStatus(status)`. When the state becomes `ready`, an effect calls `refreshSessions()` and `models()` (`:237-247`).                                                                                                                    |
| `{type:'preferences',preferences}` | `setPreferences`. Main emits this after every preferences write (`index.ts:252`).                                                                                                                                                        |
| `{type:'error',message}`           | Shows an error toast.                                                                                                                                                                                                                    |
| `{type:'menu',action}`             | `new`→`startNew`, `open`→`chooseProject`, `search`→opens the command menu, `settings`→Settings on the `'appearance'` tab, `sidebar`→toggles the sidebar (`:302-308`). Off macOS, Ctrl/Cmd+N/O/K/,/B raise the same actions (`:309-328`). |
| `{type:'session',view}`            | `setView(view)` only when `view.session.sessionId === activeId.current`. In every case it replaces the matching entry in `sessions` in place. It never adds a new entry.                                                                 |
| `{type:'sessions-changed'}`        | Debounces 250 ms, then calls `refreshSessions()`.                                                                                                                                                                                        |

**Notification** (main side only, `index.ts:89-111`)

- On a `session` event where the status goes `running`→`idle`, `notifyOnCompletion` is on and the window is not focused, main shows a system notification.
- Title: `"Muse is ready for you"`. Body: `name || title || "Your conversation has an update."`. Clicking it shows and focuses the window.

**Toasts** (`App.tsx:144-145, 194-198, 1184-1192`)

- Error toasts stay until the user dismisses them. Success toasts close after 4 s.
- The dismiss button is titled `"Dismiss notification"`. Errors use `role=alert`; success uses `role=status`.

**What the CLI sends, and what main does with it** (`muse-host.ts:510-586`)

- `session/listChanged` and `session/started` → `sessions-changed`.
- All other notifications are dropped unless their `sessionId` is in the host's `sessions` map:
  - `item/started|updated|completed` → `store.apply`. The first `userMessage` also fills `firstUserPrompt` if it is empty.
  - `item/delta` → `applyDelta(itemId, delta, field)`.
  - `turn/started` → sets `activeTurnId` and `status='running'`.
  - `turn/completed` → sets `activeTurnId=null`, `status='idle'`, `updatedAt=now`, `view.error = params.error?.message`, then emits `sessions-changed`.
  - `session/statusChanged` → sets `status`.
  - `session/nameChanged` → sets `name`, then `sessions-changed`.
  - `approval/requested`, `updated` and `resolved`, plus `userInput/requested` and `settled` → covered in sections 6 and 7.
  - `session/tokenUsage` → sets `usage`.
  - `view/gap` → `recover()`.
- Every handled notification calls `schedule()`, which coalesces `session` events to one per 32 ms per session (`:498-508`).

---

## 1. Finding `muse`

**Calls**

| Call                     | Channel       | Arguments              | Returns                                                                                 |
| ------------------------ | ------------- | ---------------------- | --------------------------------------------------------------------------------------- |
| `bootstrap()`            | `bootstrap`   | none                   | `{preferences, status: ConnectionStatus, version, home, platform}` (`index.ts:389-395`) |
| `connect()`              | `connect`     | none                   | `ConnectionStatus`                                                                      |
| `chooseCli()`            | `choose-cli`  | none                   | `string \| null`                                                                        |
| `savePreferences(patch)` | `preferences` | `Partial<Preferences>` | `Preferences`                                                                           |

- `ConnectionStatus` is `{state:'connecting'|'ready'|'missing'|'error', path?, version?, message?, fingerprintWarning?, experimental?}` (`protocol.ts:182-190`).
- The `preferences` patch is checked by `preferencesPatchSchema`: strict and partial, with `trustedProjects` and `recentProjects` omitted, and `cliPath` limited to 4096 characters (`protocol.ts:165-169`).

**How the CLI is found** (`main/cli.ts:26-104`)

- On non-Windows, main runs `$SHELL -ilc` (6 s timeout) and imports the login-shell environment.
  - If the shell fails, `shellWarning` = `"Your login shell did not respond. Using standard installation locations."`
- The search PATH is the shell's PATH plus `~/.local/bin`, `~/.muse/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin` and `/snap/bin`.
- `ELECTRON_RUN_AS_NODE` and `NODE_OPTIONS` are removed from the environment.
- Candidates: the explicit `cliPath` if set, otherwise each PATH directory joined with `muse`.
  - A candidate must be an absolute path, executable (`X_OK`), and its `--version` output must match `/^Muse Code\s/m`.
  - The version is that output with the `Muse Code ` prefix stripped.
- If nothing passes, the error is:
  - with a custom path: `"This executable is not a working Muse Code installation. Choose the muse binary or clear the custom path."`
  - without one: `"Muse Code was not found. Install the CLI, run muse login in Terminal, then reconnect."`

**Connecting** (`muse-host.ts:53-147`)

- `connect()` reuses an in-flight connect promise if there is one.
- `start()` first closes the existing host. **This clears the whole session map** (`:606-613`). It then sets status to `connecting`.
- It spawns `muse serve --trust-workspace`. On Windows, `.cmd`/`.bat` files run through `cmd.exe /d /s /c`.
- `initialize` sends:
  - `clientInfo {name:'muse_desktop', title:'Muse Desktop', version:'0.2.0'}`
  - `capabilities {userInputDialogs:true, requestedCapabilities:['sessionListStream'], experimentalApi:true}`
- It races a 15 s timeout: `"Muse did not finish connecting within 15 seconds. Check the CLI in Terminal."`
- On success, the status is:
  - `state:'ready'`, `experimental` (from `initializeResult.experimentalApi === true`), `path`, `version`
  - `message: cli.shellWarning`. So a `ready` status can carry a message.
  - `fingerprintWarning`: `"This CLI has a different protocol revision. If a feature fails, check the compatibility guide."`
- On failure: `state` is `missing` if the message matches `/not found|executable/`, otherwise `error`. `message` is the error text.
  - Both `cli.ts` messages match that regex, so a bad custom path also counts as `missing`.
- If the connection closes on its own, the status becomes `{...prev, state:'error', message:'The Muse connection closed. Reconnect to restore your saved conversations.'}` (`:117-126`).
- Calls made while not ready throw `"Muse is not connected. Reconnect in Settings."` (`:154-158`).
- Main connects automatically at launch with `preferences.cliPath` (`index.ts:974`).

**What the UI shows**

- **Sidebar footer** (`App.tsx:867-877`): a `status-dot` with the state as its class, then one of:
  - `"Connected to Muse Code"` when ready
  - `"Connecting to Muse…"` when connecting
  - `"Muse Code disconnected"` for `missing` or `error`
  - Clicking it opens Settings on the `'connection'` tab.
- **Banner** (`App.tsx:961-970`), only for `missing` or `error`:
  - Text: `status.message || "Connect Muse Code to get started."`
  - Buttons: `"Reconnect"` and `"Set up"` (with an → icon, opens the connection tab).
- **Settings, "Muse Code" tab** (`Settings.tsx:211-304`):
  - Heading `"Muse Code connection"`, with the text `"Muse Desktop runs your installed CLI and uses its existing sign-in, models, and saved conversations."`
  - Card title: `"Muse Code is connected"`, `"Connecting to Muse Code…"` or `"Muse Code is disconnected"`.
  - Card subtitle: `Version ${version}` if there is a version, otherwise `status.message`.
  - A refresh icon button, aria `"Reconnect to Muse Code"`.
  - `status.path` as a readout, and `fingerprintWarning` as an inline notice.
  - Field label `"Custom executable path"`, placeholder `"Automatic detection (recommended)"`, and a `"Browse"` button.
  - Hint: `"Leave empty to find Muse through your login shell and standard installation locations."`
  - Button `"Save & reconnect"`.
  - A `"New to Muse Code?"` block: `Install Muse Code using the official instructions, then run muse login in Terminal. Your credentials stay with the CLI.` with an `"Open installation guide"` link to `https://dev.meta.ai/docs/muse-code`.

**Choosing a custom CLI path**

- `"Browse"` calls `chooseCli()`. Main opens a file picker titled `"Choose the Muse Code executable"` (`openFile` and `showHiddenFiles`).
  - **It saves `{cliPath}` straight away** and returns the path (`index.ts:411-419`). It does not reconnect.
  - The renderer puts the path in the local text field.
- `"Save & reconnect"` calls `window.muse.savePreferences({cliPath: cliPath.trim()})` directly, not through `onSave`, then `onReconnect()` (`Settings.tsx:274-286`).
- An empty string means automatic detection.

**Reconnect** (`App.tsx:290-301`)

- Calls `connect()` and sets the returned status.
- If the result is `ready` and `activeId.current` is set, it calls `openSession(activeId)` again.
- Main first checks for active turns (`index.ts:396-410`). If there are any, it asks:
  - Message `"Reconnect while Muse is working?"`, detail `"Reconnecting closes the current CLI host and interrupts its active turns. Saved conversations can be resumed afterward."`
  - Buttons `"Reconnect"` / `"Cancel"`, with Cancel as the default.
  - Cancel returns the current status unchanged.

---

## 2. Projects and the sidebar

**Calls**

| Call                    | Channel          | Arguments       | Returns                                               |
| ----------------------- | ---------------- | --------------- | ----------------------------------------------------- |
| `listSessions(cursor?)` | `sessions`       | optional cursor | `{sessions: MuseSession[], nextCursor: string\|null}` |
| `chooseProject()`       | `choose-project` | none            | `string\|null` (a realpath)                           |

- `listSessions` maps to `session/list {limit:100, cursor?}`.

**How `recentProjects` is kept** (all in main; the renderer cannot patch it)

- `choose-project` (`index.ts:420-435`): folder picker titled `"Open a project"`, button `"Open project"`, with `openDirectory` and `createDirectory`. The realpath goes to the front of the list, without duplicates, capped at 30.
- `sessions` handler (`index.ts:437-466`): collects the unique `workspaceRoot` of every non-subagent session in the page, realpaths each one and keeps only existing directories. These are **appended after** the existing recents (unique, capped at 30). Main saves only if the count changed.
  - Easy to miss: these roots are not passed through `projectRoot()`, so a worktree folder (`.muse/worktrees/x`) can end up as a recent project.
- `open` handler (`index.ts:544-554`): puts `projectRoot(workspaceRoot)` at the front if it is missing.
- At bootstrap the renderer sets `project = recentProjects[0] || ''` (`App.tsx:228`).

**Project switcher** (`App.tsx:615-670`)

- Section header `"PROJECTS"` (collapsible), with a + icon button labelled `"Open a project"`.
- A `Select` labelled `"Current project"` with these options:
  - `""` → `"All projects"`
  - each recent project → its last path part (`projectName`)
  - the current project, if it is not in recents
  - `"__open"` → `"Open another project…"`
- Choosing a project calls `setProject` then `startNew()`. That clears the view, sets `archived=false` and switches to the chat page.

**Fetching the list** (`refreshSessions`, `App.tsx:146-172`)

- It **follows every page automatically** in a loop.
  - Results merge into a map by `sessionId`. `setSessions` and `setNextCursor` run after each page.
  - A repeated cursor throws `"Muse returned a repeated history cursor. Reconnect to refresh history."`
  - A sequence counter throws away stale runs.
- `historyLoading` is true only on the first load.

**Which sessions show, and in what order** (`App.tsx:494-506`)

- Kept only if all of these hold:
  - `!project`, or `projectRoot(session.workspaceRoot) === projectRoot(project)`. This compares raw strings, so worktree sessions appear under their parent project.
  - `kind` is not `'subagent'` or `'reminder'`.
  - The session is in `archivedSessionIds` exactly when the `archived` toggle is on.
- Sorted pinned first, then by `(lastActivityAt || updatedAt)` descending, as an ISO string comparison.

**Groups** (`conversationGroup`, `App.tsx:84-96`)

- `"Pinned"` if pinned. Otherwise by date: `"Today"`, `"Yesterday"`, `"Previous 7 days"` or `"Earlier"`.
- Groups are made from consecutive runs of the sorted list. Each group header can be collapsed (`collapsedGroups`).

**Each row** (`App.tsx:732-789`)

- Icon: a Pin if pinned, otherwise a `working-dot` if `status==='running'`, otherwise a MessageSquare. **Running is the only status badge.**
- A `"worktree"` chip if `session.worktree` is set or `worktreeParent(workspaceRoot)` matches. Its tooltip is the path.
- The title (`sessionTitle`), also used as the row tooltip.
- The project name, only in "All projects" mode.
- `<time>`: `friendlyTime(lastActivityAt||updatedAt)`, which gives `"Now"`, `"<n>m"`, `"<n>h"` or a short month/day such as `"Oct 21"` (`Primitives.tsx:127-135`).
- A hover pin button with title `"Pin conversation"` / `"Unpin conversation"` and aria `` `${Pin|Unpin} ${title}` ``.
- The open session's row has the `selected` class.

**Title order** (`sessionTitle`, `Primitives.tsx:96-126`)

- Uses `cleanPromptText(name) || cleanPromptText(title) || cleanPromptText(firstUserPrompt)`.
- `cleanPromptText` does the following:
  - removes `<tag …>…</tag>` blocks, up to 4 passes
  - drops everything up to the last closing tag
  - drops a leading `<tag…` and everything after it
  - collapses whitespace and trims
- Text longer than 76 characters is cut and trailing space removed, then `…` is added.
- Fallback: `"Untitled conversation"`.

**Section header, empty states and errors**

- Header: `"CONVERSATIONS"`, or `"ARCHIVED"` when the toggle is on.
- The archive toggle icon is labelled `"Show archived conversations"`, or `"Show conversations"` when on.
- History error: `"Could not load your conversation history."`, then the error message, then a `"Try again"` button.
- Loading (only when ready): spinner and `"Loading Muse history…"`.
- Empty (ready, not loading, no error):
  - normal: `"No conversations yet"` / `"Start a conversation in this project."`
  - archived: `"No archived conversations"` / `"Archived conversations appear here."`

**`"Load earlier conversations"`** (`App.tsx:816-837`)

- Shown when `nextCursor && !historyLoading`. It calls `listSessions(nextCursor)` and appends the new, de-duplicated sessions.
- Because the auto-loop follows every cursor, this button only shows up when a later page failed partway through.

**Pinning and archiving (M4)**

- Both are lists in the renderer's preferences, `pinnedSessionIds` and `archivedSessionIds`, toggled with `savePreferences` (`App.tsx:480-493`).
- Archiving the open session calls `startNew()`.
- Effect on the list: pinned sessions sort to the top under the `"Pinned"` group with a Pin icon. Archived sessions are hidden unless the toggle is on.
- The command menu leaves out archived sessions but **does not** leave out subagents (`App.tsx:1132-1134`).

**Other strings**

- Brand: `"Muse"` with an `"Unofficial"` tag, tooltip `"Community desktop app for Muse Code · Not affiliated with Meta"`.
- `"Search conversations"` with ⌘ K, and `"New conversation"` with ⌘ N.
- Nav items: `"Chat"`, `"Projects"`, `"Files"`, `"Docs"`, `"Settings"`.
- Breadcrumb: `projectName(project)` or `"Muse Desktop"`, then the page name, the session title, or `"New conversation"`.
- ProjectsPage (`WorkspacePages.tsx:64-127`):
  - It matches `session.workspaceRoot === path` exactly, with no `projectRoot` step.
  - Card footer: `"N conversation(s) · <friendlyTime>"`.
  - Git pills: the branch, and `"N changed"` or `"Clean"`.

---

## 3. Opening and resuming a session

**Calls**

| Call                                            | Channel  | Arguments  | Returns       |
| ----------------------------------------------- | -------- | ---------- | ------------- |
| `openSession(sessionId)`                        | `open`   | session id | `SessionView` |
| `createSession(project, modelId?, {worktree?})` | `create` | as shown   | `SessionView` |

- `SessionView` is `{session, items, approvals, questions, usage?, error?, historyNotice?}` (`protocol.ts:173-181`).

**Open is read-only** (`muse-host.ts:206-222`)

1. If the session is already in the map and `loaded`, return the cached view.
2. If it is in the map but not loaded, send `view/unsubscribe` (ignoring `sessionNotLoaded`).
3. Send `session/read {sessionId, excludeItems:false}`, then `hydrate(result, loaded=false)`.
4. Send `view/subscribe {sessionId, after: viewCursor}`. If the error is `MspError.kind==='sessionNotLoaded'`, swallow it: the session is viewed but gets no live updates.

- **Pending approvals and questions are not fetched on open.** They start empty and only fill from live events or a later resume.

**Resume happens on the first mutating call** (`resume`, `:232-247`)

- `send`, `compact`, `rename`, `setModel`, `approve`, `answer` and `cancelQuestion` each call `resume()` first.
  - If the session is not loaded: `session/resume {sessionId, history:'inline'}`, then `hydrate(…, loaded=true)`, then `approval/listPending` (sets approvals and questions), then `schedule`.
- `cancel` does **not** resume.
- Changing the model on a session you are only viewing therefore claims it.
- Main also calls `sessionProject()` for these calls (all except cancel), which **prompts for project trust** (`index.ts:287-312`):
  - Title `"Trust this project?"`
  - Message `Work with Muse in “<basename>”?`
  - Detail: `Muse can read and edit this project and use its skills, instructions, and hooks. Its existing sandbox and tool approval settings remain active.\n\n<path>\n\nOnly continue with a project you trust.`
  - Buttons `"Trust project"` / `"Cancel"`, Cancel default.
  - Cancelling throws `"Project trust was cancelled. No session was started."`

**Create** (`index.ts:467-473`, `muse-host.ts:185-204`)

- `knownProject` must match a recent project or its worktree parent, otherwise `"Choose this project using Open project first."`
- Then `trustProject`.
- Then `session/start {workspaceRoot, modelId?, worktree?:{mode:'create'}}`, `hydrate(loaded=true)`, and a `sessions-changed` event.
- Worktree creation without the experimental API: `"This Muse Code version does not offer worktree sessions."`

**hydrate and seed** (`:249-320`)

- The seed items are `history.items ?? history.snapshot.state.items ?? []`.
- `error = lastTurn.error.message`.
- `historyNotice` is `"Muse did not include earlier messages in this response."` when `history.mode==='none'`.
  - In that case, hydrate pages through `view/page {direction:'forward', limit:500, cursor}`, applying item and delta events until it reaches `viewCursor`, and **then clears `historyNotice`** (`:318`).
  - So in practice the notice never shows; it is dead code. It would render as an `inline-notice` under the transcript header.
- Errors from that paging:
  - `"Muse returned history for a different conversation."`
  - `"Muse returned a repeated transcript cursor. Reconnect and try again."`

**`view.error`**

- Set from `lastTurn.error`, from `turn/completed.error`, or from a failed gap recovery (`` `Could not recover missed updates: ${msg}` ``).
- Cleared at the start of each `send` (`:340`).
- Rendered at the end of the transcript (`Transcript.tsx:636-642`) as `"Muse couldn’t finish this turn."`, then the error, then `"Your conversation is saved. You can send a follow-up or reconnect."`

**`view/gap` recovery** (`:588-604`)

- `view/unsubscribe`, then `session/read`, then hydrate (keeping the `loaded` flag), then `refreshPending` if loaded, then `view/subscribe`.

**Renderer side** (`openSession`, `App.tsx:268-289`)

- Does nothing if the session is already open.
- A sequence counter guards against races.
- The spinner shows only when no view is open: `"Loading conversation…"` (`:1002-1006`).
- On success it sets `view`, `project = workspaceRoot || ''` and `modelId = session.modelId || ''`.
- On error it shows a toast and resets `activeId` to the previously open session.
- Other errors: `"Open this conversation before performing an action."` (`requireSession`).

---

## 4. The transcript

**Filtering** (`Transcript.tsx:517`)

- Drops items with `retracted` set, and items where `isInternalActivity` is true (`kind` is `reminderChild` or `hookRun`, `activity.ts:3-5`).
- Those internal items appear **only** in the Inspector's Activity tab.

**Grouping** (`Transcript.tsx:518-538`, `:557-567`)

- A "completed tool" is any item whose kind is not `userMessage`, `agentMessage` or `reasoning`, and whose `status === 'completed'`.
- Consecutive completed tools form a run.
- Runs of **3 or more** render as a `ToolGroup`. Runs of 2 render as two separate items.
- In-progress or failed tools, and any message, break a run.

**ToolGroup**

- Header: a check icon (always), a Layers icon, `"Ran N tools"`, then the first 3 unique titles joined with `", "`, then a total `+added −removed` if either is non-zero.
- Collapsed by default. Expanding shows each item as a `ToolItem`.

**`userMessage`** (`:570-593`)

- Text: `cleanMessageText(displayText||text) || displayText || text || ''`. Rendered as **plain text**, not Markdown.
- Heading: an avatar `"Y"`, `"You"`, the `recordedAt` time (`toLocaleTimeString`, hour numeric, minute 2-digit), and an icon-only copy button (aria `"Copy"`).

**`agentMessage`** (`:595-613`)

- Heading: the Muse avatar, `"Muse"`, a `"Composing"` label while `status==='inProgress'`, and a copy button.
- Body: Markdown of `text`, or `'…'` when the item is in progress and has no text yet.

**`reasoning`** (`ReasoningItem`, `:274-312`)

- Collapsed by default. Label is `"Thinking"` (with a spinner) while in progress, otherwise `"Reasoning summary"` (with a check).
- Body: Markdown of `summary.join('\n\n') || text || "No reasoning text was provided by the model."`

**Every other kind** (toolCall, subagent, workflow, userShell, webSearch and so on) renders as a `ToolItem` (`:112-212`)

- Title: `tool || label || role || <kind with spaces, lower case>`, so `toolCall` becomes `"tool call"`.
- Summary: `statusLine || objective || commandText || fallbackText`.
- Status icon: a spinner if `inProgress`, a check if `completed`, otherwise an ✕.
- Kind icon: Users for `subagent`, Terminal for `toolCall`, FileCode2 for anything else.
- `patchSummary` shows as `+added −removed` (the minus is a U+2212 character). `files` is not shown.
- Expanded body:
  - `objective` as a paragraph
  - `args` under the eyebrow `"INPUT"`, pretty-printed if it parses as JSON, raw otherwise
  - a `<pre>` with the first of `fullOutput || visibleOutput || result.text || failureReason || finalSummary`
  - `"Muse shortened the displayed output."` when `truncated`
  - for items with `outputRef` that have not loaded full output yet: a button `"Read stored output"`, which reads `"Loading…"` while loading
  - a footer `` `${status}` `` plus `` ` · ${(durationMs/1000).toFixed(1)}s` `` when known
- Not used anywhere: `result.summary`, `childSessionId`, `subagentId`, `agentPath`, `turnId`. Subagents have no special rendering beyond the icon.

**Stored output** (`readOutput(sessionId,itemId)`, channel `output`, returns `string`, `muse-host.ts:423-441`)

- Requires `store.get(itemId).outputRef`, otherwise `"There is no stored output for this item."`
- Calls `item/readOutput {sessionId, itemId, outputRef: outputRef.id, lengthBytes: 1048576}` and gets `{content, encoding, eof}`.
- If `encoding !== 'utf8'`: returns `"Binary output cannot be displayed as text."`
- If not `eof`: appends `"\n\n[Preview limited to 1 MB. Full output remains in Muse’s session log.]"`

**Markdown** (`MessageMarkdown`, `:62-110`)

- `react-markdown` with `remark-gfm`. Raw HTML is not rendered (the default).
- Links:
  - clicking calls `openExternal(href)`
  - main allows only `http:` and `https:`; anything else gives `"Only web links can be opened."`
  - each link gets a small external-link icon
- Images: never loaded. They render as `[Image: <alt || "External image">]`.
- Code blocks:
  - the language label comes from `language-xxx`, or `"code"` if there is none
  - a copy button labelled `"Copy"` changes to `"Copied"` for 1.8 s
  - if copying fails, the title becomes `"Could not copy. Select and copy the text."` and the text `"Select to copy"`
  - the copied text has its trailing newline removed
  - no syntax highlighting
- Inline `code` passes `className` through.

**Streaming** (main side)

- The `ItemStore` replaces an item only when the incoming revision is strictly higher. Deltas build up per field, including for items that have not arrived yet.
- `view()` (`muse-host.ts:476-496`) merges deltas **only into `inProgress` items**:
  - `text` = item.text + the accumulated `text` deltas
  - `visibleOutput` = item.visibleOutput + the accumulated `output` deltas
  - `summary[N]` += the accumulated `summary.N` deltas
- Completed items are used as they are, because they carry the full values.
- Each view is a full replacement sent to the renderer, at most one per 32 ms per session.

**Chrome** (`Transcript.tsx`)

- Header: `"Conversation with Muse"`.
- After the items: approval cards, question cards, then the error block.
- Empty state when no items are visible: `"Start a conversation"` / `"Ask a question or describe what you want to build."`
- Auto-scroll keeps following while the reader is within 110 px of the bottom.
- Scrolled further up, a button labelled `"Jump to latest message"` appears. The transcript has `role=log` and `aria-live=off`.

**Optimistic user message** (`App.tsx:422-444`)

- After sending, the renderer adds a `userMessage` with id `optimistic-<ts>`, `status 'completed'` and `text`/`displayText` set to the draft, and marks the session `running`.
- It skips this if an item with the same text already exists.
- The next `session` event replaces the whole list, so the optimistic item disappears then.
- The server's `displayText` adds `[Attached: <name>]` lines for attachments (`index.ts:609-614`).

---

## 5. Composer

**Calls**

| Call                 | Channel   | Arguments  | Returns    |
| -------------------- | --------- | ---------- | ---------- |
| `send(input)`        | `send`    | see below  | `void`     |
| `cancel(sessionId)`  | `cancel`  | session id | `void`     |
| `compact(sessionId)` | `compact` | session id | `{status}` |

- `send` input: `{sessionId, text (≤200000), attachments: string[] (≤5 ids), effort: ReasoningEffort, mode:'queue'|'steer'}`.
  - Main builds `turn/start {sessionId, input:[{type:'text',text}, …image/text parts], displayText, reasoningEffort: effort, ifBusy: mode}` (`index.ts:560-617`, `muse-host.ts:331-346`).
  - Empty input: `"Write a message or attach a file first."`
- `cancel` maps to `turn/cancel {sessionId}`.
- `compact` maps to `session/compact`.

**What submit does** (`App.tsx:330-466`)

- If there is no view, it creates a session:
  - It needs a project. If there is none it opens the project picker; cancelling the picker sends nothing.
  - It passes `modelId || undefined`, plus the worktree option when that is on.
  - After creating a worktree session it switches `project` to the worktree folder.
- It then sends, always passing `mode`.
- On error it puts the draft back and shows a toast.

**Mode: queue or steer** (`Composer.tsx:141, 436-452`)

- Composer-local state, default `'queue'`. It is **always sent**, even when idle (as `ifBusy`).
- The picker only appears while running: a `Select` labelled `"Follow-up behavior"` with `"Queue next"` and `"Steer now"`.
- The Composer is never re-created, so the chosen mode carries over across sends and between sessions.

**Running state** (`:220-231`)

- A running line: `"Muse is working…"`, or `"Finishing background tasks…"` when every in-progress item is internal (`isBackgroundOnly`, `activity.ts:18-21`).
- A hint: `"Send a follow-up to queue or steer."`
- A Stop icon button, `"Stop Muse"`, which calls `cancel`.
- The send button's aria is `"Send follow-up"` while running, `"Send message"` otherwise.

**When controls are disabled**

- Send: `voiceBusy || submitting || (!connected && !isCommand) || (!draft.trim() && !attachments.length)` (`:457-462`). Slash commands still go through while disconnected.
- Model select: while submitting, or when `models` is empty.
- Attach: while submitting.
- Voice: while submitting or disconnected.
- While submitting, the send button shows a spinner.

**Keyboard** (`:310-368`)

- Enter without Shift (and not composing) submits. **Cmd-Enter also submits**, because `metaKey` is not checked. Shift-Enter inserts a newline (the default).
- In the slash menu:
  - ↑/↓ move the selection
  - Tab, or Enter when the draft is not already an exact command name, fills in `/<name> `
  - Escape adds a space so the menu closes
- In the @mention menu: ↑/↓ move, Tab or Enter chooses, Escape closes.
- Escape also cancels a voice recording in progress. Alt/⌥V toggles voice (`VoiceInput.tsx:181-197`).
- Footer hints: `↵ Send · ⇧ ↵ New line`.

**Placeholder and footnote**

- Placeholder: `"Ask Muse about your project…"` with a project, `"Ask Muse anything…"` without.
- Footnote: `"Select a project when you send your first message."` with no project, or `"Muse will create a separate Git worktree for this conversation."` when the worktree option is on.
- The textarea grows automatically up to 200 px.

**Drafts** (`App.tsx:111, 140-141`)

- Kept in a memory-only map: `drafts[sessionId || 'new:'+project]`. Nothing is saved to disk.
- On send, the draft is cleared under both the original key and the new session id, but only if it still equals the sent text (`:445-450`).
- Attachments are **Composer-local, not per-session**, so they stay when the user switches sessions.

**Slash commands** (`commands.ts`, `App.tsx:336-400`)

- The menu shows while the draft matches `^/[a-z-]*$`. Parsing is `^/([a-z-]+)(?:\s+(.*))?$`.
- A command that is not in the list: `` `/${name} is not handled by Desktop. Use /help, or open Muse Code in the project inspector for CLI commands.` ``
- Using a command with attachments: `"Send attachments with a message, or remove them before using a command."`
- After any command the draft is cleared.

| Command    | Menu description                                 | What it does                                                                                                                                                                                                                                                  |
| ---------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/model`   | `"Choose a model, or /model <model-id>"`         | No argument: opens the Model picker (by dispatching `muse:select` with detail `'Model'`). With an id: checks it is in `models`, otherwise `"Choose one of the models available in the Model menu."`; if a view is open calls `setModel`; then sets `modelId`. |
| `/effort`  | `"Choose reasoning effort, or /effort <level>"`  | No argument: opens the `'Reasoning effort'` picker. With a level: checks it (case-insensitive), otherwise `"Choose none, minimal, low, medium, high, xhigh, max, or ultra."`; then saves `{reasoningEffort}`.                                                 |
| `/rename`  | `"/rename <conversation name>"`                  | Needs a view. With an argument: calls `renameSession` straight away. Without: opens the rename dialog.                                                                                                                                                        |
| `/clear`   | `"Start a new conversation; keep saved history"` | `startNew()`, the same as `/new`.                                                                                                                                                                                                                             |
| `/compact` | `"Compact this conversation with Muse Code"`     | Needs a view. Toast `"There is no conversation history to compact yet."` when the status is `noop`, otherwise `"Muse is compacting this conversation."`                                                                                                       |
| `/stop`    | (M4)                                             | Needs a view; calls `cancel`.                                                                                                                                                                                                                                 |

- `/compact`, `/rename` and `/stop` without a view: `"Open a conversation before using this command."`
- The rest belong to M4: `/new`, `/voice`, `/stop`, `/settings` and `/help`.

---

## 6. Approvals

**The `approve` call**

- `approve(sessionId, approvalId, choiceId)`, channel `approve`, returns `void`.
- Main resumes the session if needed, then looks up the approval in the session's current list. If it is missing or the choice is not offered: `"This approval changed. Review the current choices and try again."`
- Then it sends `approval/decide {sessionId, approvalId, choiceId, requirementId: approval.currentRequirementId}` (`muse-host.ts:385-403`).

**How the approval list stays current**

- `approval/requested` adds or replaces by `approvalId`.
- `approval/updated` merges the update into the existing approval and checks the result.
- `approval/resolved` removes it.
- `approval/listPending` runs on resume and on recovery.

**The card** (`ApprovalCard`, `Transcript.tsx:322-377`)

- Key: `approvalId:sourceIndex`. Section aria `"Approval required"`.
- Heading: `"Approval required"`, with `` `Muse would like permission to use ${toolName}.` ``
- A `<pre>` with `subject.command || subject.path || subject.host || subject.target || rawArgs`. `subject.kind` is not shown.
- One button per `availableChoices` entry:
  - Text: `label`.
  - When `scope === 'localPersistent'`, a sub-label `"Saves a rule"`.
  - Tooltip: `rulePreview`, or `"Applies once"`, `"Applies for this session"` or `"Applies as a saved policy"`, depending on scope.
  - `decision.startsWith('approved')` gives the primary style; everything else is secondary.
- **`acceptsFeedback` is ignored.** There is no feedback text field.
- All buttons are disabled while a decision is pending. The card goes away only when `approval/resolved` arrives.

---

## 7. Questions

**Calls**

- `answer(sessionId, userInputId, answers: QuestionAnswer[])` → `userInput/answer {sessionId, userInputId, answers}`.
- `cancelQuestion(sessionId, userInputId)` → `userInput/cancel`.
- Both resume the session first. Main checks the answers with `z.array(answerSchema)`.

**`answerSchema`** (`protocol.ts:242-247`)

```ts
{ questionId: string, selectedLabel?: string, selectedLabels?: string[], freeText?: string /* max 500 */ }
```

**How the question list stays current**

- `userInput/requested` adds or replaces by `userInputId`. `userInput/settled` removes it.

**The card** (`QuestionCard`, `Transcript.tsx:379-501`)

- Heading: `"Input required"`, with `"Muse has a question before continuing."`
- One fieldset per question. The legend is `question.question`. **`header` appears only in the free-text field's aria-label**: `` `Your answer: ${header}` ``.
- Options use radio buttons for `single` and checkboxes for `multiple`. Each shows a bold `label` and an optional `description`.
- Single: clicking sets `{questionId, selectedLabel}`.
- Multiple: clicking toggles the label in `{questionId, selectedLabels}`.
- Free text: placeholder `"Or write your own answer…"`, maximum 500 characters. Typing sets `{questionId, freeText}`.
  - Easy to miss: an answer is either free text or a selection, never both. Typing wipes any selection, and selecting wipes the typed text.
- Continue is enabled when every question has an answer and one of these holds:
  - `freeText.trim()` is non-empty, or
  - `selectedLabel` is set, or
  - mode is `multiple` and the count is between `minSelections ?? 1` and `maxSelections ?? ∞`.
- The max is not enforced on the checkboxes; going over it just disables Continue.
- Submit sends `Object.values(answers)`. Free text is sent untrimmed.
- Buttons: `"Skip question"`, which calls `cancelQuestion`, and `"Continue"`, which reads `"Sending…"` while pending.
  - The card goes away when `userInput/settled` arrives.

---

## 8. Model and effort

**`models(sessionId?)`**

- Channel `models`; maps to `model/list {sessionId?}` and returns `MuseModel[]`.
- Each model: `{modelId, displayLabel, providerId, isDefault, isActive, contextLimit, defaultReasoningEffort?, reasoningEffortVariants?[{tier, description?}]}`.
- The renderer calls it **once, with no session id**, each time the status becomes ready.
  - It sets `models`, and `modelId` = current value `||` the model with `isDefault`'s id `|| ''` (`App.tsx:240-246`).

**The model picker** (`Composer.tsx:392-408`)

- A `Select` labelled `"Model"` with a `✳` icon.
- Options are `displayLabel || modelId` for each model.
- If the current `modelId` is not in the list, an extra first option is added with label `modelId || "CLI default"`.
- **`isActive`, `isDefault` (beyond the initial default), `contextLimit`, `defaultReasoningEffort` and `reasoningEffortVariants` are never shown or used.**
- The `Select` popover has a heading with the label and a check mark on the selected option. Keyboard: arrows, Home/End, Enter/Space, Escape/Tab, and type-ahead with a 700 ms window (`Select.tsx`).

**`setModel(sessionId, modelId)`**

- Channel `set-model`, after the trust check. Maps to `session/setModel {sessionId, model:{modelId}}`.
- It resumes first, then sets `view.session.modelId` and schedules an update (`muse-host.ts:374-383`).

**Changing the model in the renderer** (`App.tsx:467-479`)

- With no view, it only sets local `modelId`, which is used at create time.
- With a view, it sets `modelId` only after `setModel` succeeds.
- Opening a session sets `modelId = session.modelId || ''`.
- `startNew()` does **not** reset `modelId`, so a new conversation takes the last opened session's model.

**Effort**

- A single global preference, `preferences.reasoningEffort`, default `'high'` (`protocol.ts:156`). It is not stored per session.
- The picker is a `Select` labelled `"Reasoning effort"` with all 8 values from `effortSchema`. Labels are capitalized, except `xhigh`, which shows as `"Extra high"` (`Composer.tsx:409-420`).
- Changing it calls `savePreferences({reasoningEffort})`.
- Every `send` passes `effort: preferences.reasoningEffort`, which becomes `turn/start.reasoningEffort`.
- The effort list does not depend on which model is selected.

---

## 9. Rename

**Where it lives**

- The conversation actions menu (the `…` icon, aria `"Conversation actions"`) has a `"Rename conversation"` item (`App.tsx:919-926`).
- `/rename` with no argument opens the same dialog. `/rename <name>` renames directly.

**Dialog** (`App.tsx:1147-1183`)

- Title `"Rename conversation"`.
- Label `"Conversation name"`, autofocused, max length 200.
- It starts filled with `sessionTitle(view.session)`. That title is cleaned and may be **cut to 76 characters with a `…`**, so saving without editing can rename the session to the shortened text.
- Buttons `"Cancel"` and `"Save"`. Save is disabled while the trimmed name is empty.
- Success closes the dialog; errors show a toast.

**The `rename` call**

- `renameSession(sessionId, name)`, channel `rename`. Main checks `z.string().trim().min(1).max(200)`, which trims the name, after the trust check.
- Host: resume, then `session/rename {sessionId, name}` returning `{name?}`. If a name comes back, it updates `view.session.name` and schedules an update. It always emits `sessions-changed` (`muse-host.ts:359-372`).
- `session/nameChanged` events from the CLI also update the name.

---

## 10. Usage

- **Source:** only the `session/tokenUsage` notification. Its `params.cumulative {promptTokens, outputTokens, totalTokens}` becomes `view.usage {input, output, total}` (`muse-host.ts:570-578`). It is not filled on open or resume.
- **Where it shows:** only at the bottom of the Inspector (`Inspector.tsx:469-485`), when `view.usage` is set.
  - Eyebrow `"SESSION USAGE"`, then rows `"Input"`, `"Output"` and `"Total tokens"`, each formatted with `toLocaleString()`.
- **Activity tab** (where reminders and hooks go), in the same Inspector (`Inspector.tsx:168-172, 434-467`):
  - It lists every item that is not retracted and is not a `userMessage`, `agentMessage` or `reasoning`. That includes `reminderChild` and `hookRun`.
  - Each entry has a status icon and a title from `activityTitle`:
    - `` `Reminder · ${reminderAgentId}` `` or `"Background reminder"`
    - `label || "CLI hook"` for hooks
    - otherwise `tool || label || <Kind In Title Case>`
  - Detail line for reminders: `"Keeps the turn open · "` when `blocking`, then `"Running"` or the status. For other items: `statusLine || objective || fallbackText || status`.
  - Empty state: `"No activity yet"` / `"Tool calls, file edits, and agent activity appear here."`
  - The tab label shows the item count.
