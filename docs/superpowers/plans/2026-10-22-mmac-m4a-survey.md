# Electron parity survey for mMac M4a (2026-10-22)

Three read-only surveys of the Electron app, made for `docs/superpowers/specs/2026-10-22-mmac-m4a-design.md`. They record Electron's exact strings, calls, limits and edge cases. The spec says where mMac differs. File:line references are to `mac-m3` at `b537661`, before Electron was removed.

- Part 1: ⌘K search, pinning and archiving, Markdown export
- Part 2: composer commands, `@file` mentions, attachments
- Part 3: voice input, the open-in actions, the size baseline

---

## Part 1: ⌘K search, pinning and archiving, Markdown export

Source: a read-only survey of the Electron renderer and main process, plus the headless backend and mMac's Swift code. The checkout is on `mac-m3` at `b537661`. `git diff origin/extensions -- src` is empty, so `src/` matches the M1 survey's source.

Context from the M1 survey (`docs/superpowers/plans/2026-10-21-mmac-m1-electron-survey.md`) that this survey relies on:

- IPC replies are `{ok:true,value}` or `{ok:false,error}`; the preload turns a failure into `new Error(error)` (section 0).
- The `preferences` IPC patch is strict and partial (section 1). `pinnedSessionIds` and `archivedSessionIds` are in the patch schema; `trustedProjects` and `recentProjects` are not.
- Section 2 already records the sidebar rules for pins and archives. This survey adds the menus, the ⌘K list and the export.

All paths are relative to `/Users/dom/Documents/Claude/40-49 Outside Work/42 Muse Desktop/`.

---

### 1. ⌘K search, grouped (the command menu)

### How it opens (`App.tsx`, `main/index.ts`)

- macOS native menu: **View › Command menu**, accelerator `CmdOrCtrl+K` (`main/index.ts:873`). It emits `{type:'menu',action:'search'}`, and the renderer calls `setCommands(true)` (`App.tsx:302-305`).
- Off macOS, a window `keydown` listener turns Ctrl/Cmd+K into the same action (`App.tsx:309-328`).
- Two buttons also open it: the sidebar button `"Search conversations"` with a `kbd` of `⌘ K` (`App.tsx:571-577`; `Ctrl K` off macOS), and the header icon button labelled `"Search conversations and commands"` (`App.tsx:910`).
- ⌘K never toggles. If the menu is open, `setCommands(true)` does nothing. Esc, the backdrop and a chosen result close it.

### What it searches

Source: the `commands` array (`CommandMenu.tsx:40-122`). There are exactly three kinds of entry. **It does not search files, projects, or message text.**

1. Three fixed actions.
2. Every session passed in as `sessions`.
3. Five fixed theme commands.

**The sessions passed in** (`App.tsx:1130-1135`): `sessions.filter(s => !preferences.archivedSessionIds.includes(s.sessionId))`.

- Archived sessions are left out.
- Subagent and reminder sessions are **not** left out.
- The current project is **not** applied. All projects are searched.
- The order is whatever order the `sessions` state has: the CLI's `session/list` order, with each page appended (`App.tsx:146-172`). The command menu does not sort. Whether the CLI returns newest first is not stated in this repo. Check it against the live CLI before copying the order. If it does not, the "Recent conversations" label is wrong.

### Entries, verbatim

All entries have a title, a subtitle, an icon, a shortcut string and an action. `modKey` is `⌘` on darwin and `Ctrl` elsewhere (`:39`). The shortcut text has a space: `⌘ N`.

| id          | Group                | Title                   | Subtitle                                                                    | Shortcut | Action                              |
| ----------- | -------------------- | ----------------------- | --------------------------------------------------------------------------- | -------- | ----------------------------------- |
| `new`       | Actions              | `New conversation`      | `Start a conversation`                                                      | `⌘ N`    | `startNew`                          |
| `open`      | Actions              | `Open project`          | `Choose a folder on your Mac` (darwin); `Choose a project folder` otherwise | `⌘ O`    | `chooseProject` (the folder picker) |
| `settings`  | Actions              | `Open settings`         | `Appearance and Muse Code connection`                                       | `⌘ ,`    | `setSettings('appearance')`         |
| session id  | Recent conversations | `sessionTitle(session)` | `projectName(workspaceRoot)` if it has a root, else `Conversation`          | none     | `openSession(id)`                   |
| `muse`      | Themes               | `Switch to Muse`        | `Electric blue`                                                             | none     | save `{theme:'muse'}`               |
| `daylight`  | Themes               | `Switch to Daylight`    | `Warm and light`                                                            | none     | save `{theme:'daylight'}`           |
| `moonlight` | Themes               | `Switch to Moonlight`   | `Soft and dark`                                                             | none     | save `{theme:'moonlight'}`          |
| `grove`     | Themes               | `Switch to Grove`       | `Natural green`                                                             | none     | save `{theme:'grove'}`              |
| `plush`     | Themes               | `Switch to Plush`       | `Blue mascot close-up`                                                      | none     | save `{theme:'plush'}`              |

- Group order is fixed by array position: Actions, Recent conversations, Themes. Groups are not computed. A heading draws wherever the group name differs from the previous entry (`:172-174`).
- The heading text in the source is mixed case (`Actions`, `Recent conversations`, `Themes`). CSS shows it as **uppercase** (`.command-group-heading`, `styles.css:2739-2746`: 11px, weight 600, letter-spacing 0.06em, `text-transform: uppercase`).
- There is no `system` theme command.
- mMac keeps only Muse and Moonlight (`ThemeName`, `SettingsRules.swift`; test `themesKeepOnlyMuseAndMoonlight`). The Themes group in mMac should have only `Switch to Muse` / `Electric blue` and `Switch to Moonlight` / `Soft and dark`. This is an inference. Confirm it with Dom.
- `sessionTitle` is the M1 survey's section 2: cleaned name, then title, then first prompt, cut at 76 characters, fallback `"Untitled conversation"`. mMac already has `SessionTitle.of`.

### Matching, ordering and the cap (`:123-126`)

```
.filter(entry => `${entry.title} ${entry.subtitle}`.toLowerCase().includes(query.toLowerCase()))
.slice(0, 30)
```

- Case-insensitive substring match against `title + " " + subtitle`. One space joins them, so a query can span the two. For example `conversation start` matches the New conversation action.
- The query is **not** trimmed. A trailing space is part of the needle.
- No tokenizing, no fuzzy matching, no scoring. Ranking is the array order. A better match never moves up.
- For a conversation, the subtitle is the project folder name. Typing a project name therefore finds its conversations. Message bodies and unseen parts of long titles are not searched. A title is matched as shown, after cleaning and the 76-character cut.
- Theme subtitles match too. `dark` finds Moonlight and `blue` finds Muse and Plush.
- **The cap of 30 applies to the whole filtered list.** With an empty query the list is 3 actions, then conversations, then 5 themes. With 22 or more conversations the Themes group is cut off and never shown. With 28 or more, conversations cut each other off too. Themes then appear only when a query removes enough conversations. Copy this exactly, or decide on purpose not to.
- The default selection after typing is the first match (`setSelected(0)` in `onChange`).

### Keyboard and mouse (`:144-167`, `:170-189`)

- The input has `autoFocus`.
- `ArrowDown`: `selected = min(selected + 1, count - 1)`. It clamps and does not wrap.
- `ArrowUp`: `selected = max(0, selected - 1)`. It clamps and does not wrap.
- `Enter`: `invoke(selected)`. Both arrows and Enter call `preventDefault`.
- Esc closes the menu through the native `<dialog>` `cancel` event (`Primitives.tsx:34-70`, `onCancel={onClose}`).
- A click on the dialog backdrop closes it. The dialog's own heading and close button exist but are hidden (`.command-dialog .dialog-heading {display:none}`). The dialog's accessible name is `"Search"`.
- Mouse: `onMouseEnter` sets `selected` to the hovered row. A click invokes that row.
- `invoke(i)` calls `onClose()` first, then `command.action()`, so the menu is gone before the action runs.
- An effect scrolls the selected row into view (`block:'nearest'`) after every render (`:127-132`). `commands` is a new array on each render.
- Not handled: Home, End, PageUp, PageDown, Tab as navigation, and IME composition. Enter during composition would invoke (`isComposing` is not checked).
- If `selected` is past the end after the list shrinks (a session event while the menu is open), Enter does nothing. `invoke` checks that the entry exists.

### Strings, verbatim (`CommandMenu.tsx`)

- Input `aria-label`: `Search commands and conversations`
- Placeholder: `Search commands and conversations…` (a single ellipsis character)
- Empty state: `No matches. Try a project or conversation name.` (`.command-empty`, centered)
- Footer, left to right: `↑` `↓` then ` Navigate`; `↵` then ` Open`; `esc` then ` Close`. The arrows and the keys are `kbd` elements.
- Row right side: the shortcut in a `kbd` if there is one, else an `ArrowUpRight` icon.
- Row icons: Plus, FolderOpen, Settings2, MessageSquare (conversations), Palette (Muse), Sun, Moon, Leaf, Smile.
- Dialog: 580 px wide, `max-width: calc(100vw - 60px)`, top margin `min(17vh, 140px)`. Results area: `max-height: 360px`, `overflow: auto`.

### What each result does when chosen

| Result           | Effect                                                                                                                                                                                                                                                    |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| New conversation | `startNew()`: page to chat, clears the view, `setArchived(false)` (`App.tsx:249-256`)                                                                                                                                                                     |
| Open project     | `chooseProject()`: native picker; on a choice `setProject(chosen)` then `startNew()`                                                                                                                                                                      |
| Open settings    | Settings on the `'appearance'` tab                                                                                                                                                                                                                        |
| A conversation   | `openSession(id)` (`App.tsx:268-296`): page to chat, `openSession` call, then **`setProject(opened.session.workspaceRoot \|\| '')`**. Opening from ⌘K therefore also changes the sidebar's project filter to that session's root, even from All projects. |
| A theme          | `savePreferences({theme})`. The error toast shows on failure.                                                                                                                                                                                             |

### IPC and `src/main`

- Opening the menu uses no IPC. The `menu` event comes from the native menu or from a renderer key listener.
- Choosing a result uses existing channels: `open` (`index.ts:544-554`), `choose-project` (`:420-435`) and `preferences` (`:436`).

### Headless backend

- Nothing is needed. The search is pure renderer logic over data mMac's `Workspace` already holds: `sessions`, `recentProjects`, `theme`.

### What mMac has

- No command menu, no ⌘K, no View menu item. `MMacApp.swift` defines File (New conversation ⌘N, Open project… ⌘O), View › Show Inspector (⌥⌘I) and Edit › Find only.
- Settings is opened by the standard Settings scene (⌘,).
- Reusable pieces:
  - `SessionTitle.of`, `ProjectPath.name(of:)` (`SidebarSections.swift`).
  - `ThemeName` with `label` and `hint`, which already match the Electron strings.
  - `workspace.startNew()`, `workspace.open(id)`, `workspace.selectProject`, `controller.openProject()`.
  - `workspace.save(PreferencesPatch(theme:))`.
  - `workspace.sessions` keeps the CLI's order (`refreshSessions` builds `order`).
- Suggested split: a pure `CommandMenuModel` in MuseKit with the entries, the filter, the cap of 30 and the group headings, tested like `SidebarSections`. A SwiftUI sheet or popover in `mMac/` and a View menu command with ⌘K.
- For matching, use `lowercased().contains(...)`. Do **not** use `localizedStandardContains`. It ignores diacritics and would differ.

### Tests that cover it

- e2e `tests/e2e/desktop.spec.ts:259-277` ("real project files, docs and commands are accessible"): clicks `Search conversations and commands`, fills `moonlight`, presses Enter, and expects `data-theme="moonlight"` and no open dialog.
- Nothing covers grouping, the 30 cap, arrow clamping, the empty state, or the sessions list.

---

### 2. Pinning and local archiving

### Where they are stored

- Two arrays of session ids in the preferences file: `pinnedSessionIds: string[]` and `archivedSessionIds: string[]` (`shared/protocol.ts:137-138`; defaults `[]` at `:154-155`).
- File: `preferences.json` in Electron's `userData` folder. `index.ts:66-70` sets `userData` to `<appData>/muse-desktop`, so `~/Library/Application Support/muse-desktop/preferences.json` (`index.ts:81`). The write is atomic: write `<path>.tmp` with mode 0600, then rename (`main/preferences.ts`).
- mMac's file is `<dataFolder>/preferences.json`, with `dataFolder` under `~/Library/Application Support/mMac` (`backend.ts:207`, spec line 80). **The two apps do not share pins or archives.** The spec says mMac never reads the Electron app's data. This survey did not open either file.
- Nothing is stored per session in the CLI. README line 113 says: "Archiving only hides a conversation in Desktop; it does not delete the CLI session."
- Nothing prunes the arrays. An id for a session that no longer exists stays forever. Nothing sets an order. A pinned list has no pin time.

### IPC

- There is no pin or archive channel. Both use the generic `preferences` channel:
  - `savePreferences(patch)` in the preload.
  - `handle('preferences', v => savePreferences(preferencesPatchSchema.parse(v)))` (`index.ts:436`).
  - `savePreferences` in `index.ts:241-256`: serialized through a promise queue, `preferencesSchema.parse({...preferences, ...patch})`, then `writePreferences`, then emit `{type:'preferences',preferences}`. It returns the full snapshot.
- The patch **replaces the whole array**. The renderer computes the new array from its current `preferences` state (`App.tsx:480-493`):
  - Pin: add the id at the end, or filter it out.
  - Archive: the same.
  - Two quick toggles before the first reply can lose the first one. The second is computed from the state before the first reply lands. Electron has this window. mMac should compute from the latest `workspace.preferences`, and serialize toggles.
- `savePreferences` in the renderer (`App.tsx:173-181`) calls the IPC, sets state from the reply, and shows an error toast on failure. The error text is the raw message from the main process.

### Headless backend

- **Already exposed.** `method('preferences', …)` (`backend.ts:339`) takes the same patch schema, so `{pinnedSessionIds: [...]}` and `{archivedSessionIds: [...]}` work today. It emits the `preferences` event with the full set.
- No new backend method is needed.
- Test: `tests/unit/files.test.ts:64-92` ("changes only supplied settings…") proves the patch schema accepts both fields. `headless-backend.test.ts:309-317` tests the method, but not with pins or archives.

### What mMac has, and what is missing

- `MuseBackend.Preferences` (`Models.swift:374-422`) has **neither field**. The decoder ignores unknown keys, so the arrays arrive from the backend and are dropped.
- `PreferencesPatch` (`Models.swift:424-455`) has neither field.
- `Workspace.save(_:)` exists (`Workspace+Actions.swift:148-156`).
- `SidebarSections.build` (`SidebarSections.swift:87-110`) has no pinned or archived input. Its doc comment says "pinning and archiving arrive in M4". It sorts by activity, descending, with no pinned-first rule. Its `group` function returns only the four date groups.
- `SidebarView.swift` has no pin button, no archive toggle, no `ARCHIVED` header, and no conversation menu. Its empty state is the non-archived text only.
- Needed:
  - Add both arrays to `Preferences` (defaults `[]`) and to `PreferencesPatch`.
  - Extend `SidebarSections.build` with pinned ids and an archived flag, and the archived ids.
  - Add Workspace methods that toggle by reading the current preferences.
  - Add the UI.
- The M0 fixture in `MuseBackendTests/ModelsTests.swift:39` already carries both fields.

### Sidebar behavior (`App.tsx`)

**List rules** (`visibleSessions`, `:494-506`):

- Keep a session only if it matches the project filter (`projectRoot` compare), its `kind` is not `subagent` or `reminder`, and `archivedSessionIds.includes(id) === archived`. The `archived` flag is the toggle state.
- Sort: pinned first (`Number(pinned(b)) - Number(pinned(a))`), then `(lastActivityAt || updatedAt)` descending by `localeCompare` of the ISO strings.

**Groups** (`conversationGroup`, `:84-96`, and `groupedSessions`, `:507-515`):

- `Pinned` if the id is pinned. Otherwise `Today`, `Yesterday`, `Previous 7 days`, `Earlier` by local midnight boundaries on `lastActivityAt || updatedAt`.
- Pinned wins in the archived view too. An archived-and-pinned session shows under `Pinned` there.
- Groups are consecutive runs of the sorted list. Each header is a button with `aria-expanded` and a chevron. Collapse state is `collapsedGroups[groupName]`. It is shared between the normal and archived views.

**Row** (`:732-789`):

- Icon: `Pin` (13px) if pinned, else the `working-dot` if running, else `MessageSquare` (14px). A pinned running session shows the Pin, not the dot.
- Hover pin button, class `row-pin`: `title` is `Pin conversation` or `Unpin conversation`. `aria-label` is `` `${Pin|Unpin} ${sessionTitle(session)}` ``. A `Pin` icon at 12px. It is at `opacity:0` until row hover or keyboard focus (`styles.css:615-630`). While the row is hovered, the `<time>` is hidden (`:631-633`). Clicking it calls `togglePin`.
- The other row parts are in the M1 survey, section 2.

**Section header and archive toggle** (`:672-692`):

- Header text `CONVERSATIONS`, or `ARCHIVED` when the toggle is on. It is a collapse button with `aria-expanded`.
- Next to it, an `IconButton` with an `Archive` icon (13px), `active` when on. Its label is `Show archived conversations`, or `Show conversations` when on. The label serves as the tooltip and the aria-label.
- The toggle is a local `useState`, `archived`. It is not saved. **`startNew()` resets it to `false`** (`:255`). That includes choosing a project from the switcher.

**Empty states** (`:805-815`):

- Normal: `No conversations yet` / `Start a conversation in this project.`
- Archived: `No archived conversations` / `Archived conversations appear here.`
- Shown when the visible list is empty, history is not loading, there is no error, and the status is ready.

### Conversation actions menu (`App.tsx:911-951`)

- Shown only when a session is open (`view`). A `<details className="conversation-menu">` whose `<summary>` has `aria-label="Conversation actions"` and an `Ellipsis` icon (19px). The panel is `.popover`, `min-width: 205px`, right-aligned under the button.
- Buttons, in order, verbatim:
  1. `Rename conversation`
  2. `Pin conversation` or `Unpin conversation`. It depends on whether the **open** session is pinned. No icon.
  3. `Export as Markdown`, with a `Download` icon (13px).
  4. `Archive in Desktop`, with an `Archive` icon (13px), or `Restore conversation` when the sidebar's `archived` toggle is on.
- **Quirk:** the Archive/Restore label follows the sidebar toggle (`archived`), not whether the open session is actually archived. Normally the two agree. They would disagree if an archived session were open while the toggle is off. No route to that state was found. The sidebar, ⌘K and `startNew` all keep archived sessions out of the normal view, and `WorkspacePages.tsx` has no session-open prop (grep for `onSession` finds nothing there). If it happened, the button would read `Archive in Desktop` but the action would unarchive. mMac should decide the label from the id's actual membership. That is a deliberate divergence, so tell Dom.
- Nothing closes the `<details>`. No click handler was found, so Pin and Export leave the popover open until the summary is clicked again. Archive closes it because `startNew()` clears `view`, and `{view && …}` unmounts the menu. This is inferred from the code, not observed.
- There is no confirmation dialog for archive, unarchive, pin or unpin. There is no toast for any of them.

### Archive behavior (`toggleArchive`, `App.tsx:486-493`)

- Toggles the id in `archivedSessionIds`, then `if (sessionId === view?.session.sessionId) startNew()`. Archiving or restoring the open session closes it and returns to the New conversation screen, with `archived` reset to `false`.
- Restore while in the archived view: the session leaves the archived list at once. If it was the open one, the view resets to the normal list.
- The id is not removed from `pinnedSessionIds` when archived. A pinned session stays pinned in the archive.
- ⌘K leaves archived sessions out (above).
- **A new message to an archived conversation: nothing happens.** There is no code anywhere (`App.tsx`, `main/`, `shared/`) that reads `archivedSessionIds` besides the list filter, the command menu filter and the toggle. You can open an archived session from the ARCHIVED list and keep chatting. It stays archived and keeps its place in the archived list. The `session` and `sessions-changed` events replace the entry in `sessions` in place, so only its time and order change. It does not return to the normal list. It never unarchives itself.
- The CLI is never told. Nothing is deleted or renamed in the CLI session.
- A running archived session is hidden from the normal list. The completion notification for it (M1 survey, section 0) still fires. The notice does not check archives.

### Tests that cover it

- `tests/unit/files.test.ts:64-92`: the patch schema round-trips both fields and a patch leaves the others alone.
- `tests/e2e/desktop.spec.ts:149-193`: saves `pinnedSessionIds: ['regression-pin']` and `archivedSessionIds: ['regression-archive']` through the API and checks they survive theme and effort changes and a reload.
- Nothing clicks the pin button, the archive toggle or the menu. Nothing tests ordering, grouping, or an archived session that gets a message.

---

### 3. Markdown export of a conversation

### Trigger

- Only one: **Conversation actions (⋯) › `Export as Markdown`** (`App.tsx:931-944`). It is visible only when a conversation is open.
- No keyboard shortcut. No native menu item (File has New conversation, Open project…, Close). No command-menu entry. No composer command (the list in `commands.ts` has none).
- The click handler calls `window.muse.exportSession(view.session.sessionId)`.
  - A string path in the reply: `showSuccess('Conversation exported to Markdown.')`. The toast closes after 4 s (M1 survey, section 0).
  - `null` (cancelled): nothing.
  - An error: `showError(error.message)`. The error toast stays until dismissed.
- Preload: `exportSession: (sessionId) => invoke('export', sessionId)` (`preload/index.ts:63`). Type: `exportSession(sessionId): Promise<string | null>` (`protocol.ts:318`).

### Main-process code (`main/index.ts:711-731`, channel `muse:export`)

```ts
handle('export', async (value) => {
  const view = muse.getView(id.parse(value))
  const title = view.session.name || view.session.title || 'Muse conversation'
  const result = await dialog.showSaveDialog(window!, {
    title: 'Export conversation',
    defaultPath: `${title.replace(/[^\p{L}\p{N} _-]/gu, '').slice(0, 80)}.md`,
    filters: [{ name: 'Markdown', extensions: ['md'] }],
  })
  if (result.canceled || !result.filePath) return null
  const content = [
    `# ${title}`,
    `Project: ${view.session.workspaceRoot || 'None'}`,
    ...view.items.map(
      (item) =>
        `## ${item.kind === 'userMessage' ? 'You' : item.kind === 'agentMessage' ? 'Muse' : item.tool || item.kind}\n\n${item.displayText || item.text || item.visibleOutput || item.fallbackText || item.summary?.join('\n') || item.objective || ''}`,
    ),
  ].join('\n\n')
  await writeFile(result.filePath, `${content}\n`, { mode: 0o600 })
  return result.filePath
})
```

`MuseHost.getView(sessionId)` (`muse-host.ts:460-462`) returns the live, in-memory view of an **opened** session. It folds in-progress streaming text (`muse-host.ts:472-490`). It reads no file and calls no CLI method.

### Exact format

- Parts are joined with `"\n\n"`. The file ends with one `"\n"`. Mode is `0600`.
- Line 1: `# <title>`. The title is `name || title || 'Muse conversation'`. It is the **raw** `name` or `title`, **not** `sessionTitle()`. No tag cleanup, no whitespace collapse, no 76-character cut, and **no `firstUserPrompt` fallback**. A session with neither name nor title is exported as `Muse conversation`, even if the sidebar shows its first prompt.
- Line 3: `Project: <workspaceRoot or None>`. It is the full path, not the folder name.
- Then **one `## ` section per item in `view.items`, in order, with no filtering**. This covers user messages, agent messages, reasoning, tool calls, hook runs, reminder children, retracted items and in-progress items.
- Heading text:
  - `You` for `userMessage`.
  - `Muse` for `agentMessage`.
  - Otherwise `item.tool`, else `item.kind` (for example `shell`, `reasoning`, `hookRun`).
- The body is the first non-empty of, in this order:
  1. `displayText`
  2. `text`
  3. `visibleOutput`
  4. `fallbackText`
  5. `summary.join('\n')`
  6. `objective`
  7. else the empty string
- The body is written as is. There are no fences added, no quoting, no escaping. A message's own code fences pass through. Tool **arguments** and `commandText` are never written, only output. Reasoning items give their `summary` lines joined by newlines.
- An item with no body gives `## <heading>\n\n` followed by the `\n\n` join, so a visible run of four newlines between it and the next heading.
- **There are no dates, times, durations, model names, or statuses anywhere in the file.**
- A stored output that is large (`outputRef`, fetched by the `output` channel) is **not** read. Only the `visibleOutput` already in memory is exported.
- Worked example, from a throwaway script run in the scratchpad that copies the two expressions (`sim.mjs`, not run from the repo):
  - Input: name `Fix: the "bug" / ok 🎉`, no root, items: user `Hello`; reasoning with summary `["think a","think b"]`; shell with output `a\nb`; an `edit` tool with no text; agent `Done.` plus a code fence; a `hookRun` with `fallbackText`.
  - Default file name: `Fix the bug  ok .md`
  - File text: `# Fix: the "bug" / ok 🎉`, blank line, `Project: None`, blank line, `## You`, blank, `Hello`, blank, `## reasoning`, blank, `think a`, `think b`, blank, `## shell`, blank, `a`, `b`, blank, `## edit`, then four newlines, `## Muse`, blank, `Done.`, the fence, blank, `## hookRun`, blank, `hook`, then one final newline.

### Save dialog

- `dialog.showSaveDialog(window!, …)` is a sheet on the main window.
- `title: 'Export conversation'`. The Electron docs say a save dialog title does not show on macOS. That is from memory and not checked in this repo. Treat it as invisible on a Mac.
- Filter: name `Markdown`, extension `md`.
- `defaultPath` is a **bare file name with no folder**: `title` with every character outside letters, digits, space, `_` and `-` removed (`\p{L}\p{N}`, Unicode-aware), cut to 80 UTF-16 units, plus `.md`.
  - Dots, colons, slashes, emoji and punctuation are stripped. Spaces stay, so runs of spaces can appear.
  - An all-symbol title gives the file name `.md`.
  - The `.slice` can split a surrogate pair for letters outside the BMP.
- With no folder, the folder is whatever macOS gives a save panel by default. This repo does not set it.
- Overwrite confirmation is the native panel's.
- The file is written after the dialog closes. The view was read **before** the dialog opened. Text that streams in while the panel is up is not included.

### Errors, verbatim

- Session not open in the host: `Open this conversation before performing an action.` (`muse-host.ts` `requireSession`). In Electron the open session is always live, so this appears only after a reconnect or restart.
- A bad or empty id: the Zod text, converted by `messageOf` (M1 survey, section 0) into `Muse could not read “<field>”. Restart the app to use the latest version, then try again.` or the shorter form.
- Write failure: Node's own message, for example `EACCES: permission denied, open '<path>'`. It reaches the renderer unchanged as an error toast.
- Cancel: returns `null`. No toast.
- Success toast: `Conversation exported to Markdown.`

### Headless backend

- **Not exposed.** `method('export', …)` is absent. `tests/unit/headless-parity.test.ts:49` lists `'export'` in `notYet`.
- `Muse`'s `Pick<MuseHost,…>` (`backend.ts:50-70`) does not include `getView`.
- The spec (`docs/superpowers/specs/2026-10-21-mac-app-design.md:72`) says the pattern is "the app shows the native panel and sends the chosen path. The backend validates it as today." That points to a backend `export` method that takes a path, like `add-project`.
- Two ways to do it:
  1. **Backend `export`** (follows the spec). Arguments `(sessionId, path)`. Add `'getView'` to the `Muse` pick, and `pathSchema.parse(path)` as `add-project` does. Write the same string with `writeFile(..., {mode: 0o600})`. Return the path. Remove `'export'` from `notYet` in the parity test. The name already exists in `index.ts`, so no `headlessOnly` entry is needed. The format then lives in one place and a vitest test can pin it. The fake `Muse` in `tests/unit/headless-backend.test.ts` needs `getView`. Swift supplies the title and the default file name for the panel.
  2. **Swift only.** Build the same string from `Workspace.view` (its `TranscriptItem` has every field used: `displayText`, `text`, `visibleOutput`, `fallbackText`, `summary`, `objective`, `tool`, `kind`). Write it with `FileManager` and 0600. No protocol change. The format would live in Swift and be tested in MuseKit.
- Recommendation: option 1. It matches the spec and keeps one copy of the format.
- Either way, `Workspace.view` already holds the live view and `rename` shows `name`. mMac's `Session` has `name`, `title` and `workspaceRoot`.

### What mMac has

- Nothing. No export code, no save panel. `NSOpenPanel` appears three times in `AppController.swift` (`:272`, `:282`, `:355`) and `SheetAlert.run` runs only an `NSOpenPanel` (`SheetAlert.swift:123`). A save panel would need a sibling `run(_ panel: NSSavePanel)`.
- No conversation menu or toolbar action. The only toolbar item is the inspector toggle (`RootView.swift`).

### Tests that cover it

- None. There is no unit or e2e test that calls `export` or `exportSession`. The parity test only lists the channel name.

---

### Ambiguities and surprises

1. **The cap of 30 hides Themes.** With 22 or more conversations the empty-query list never shows the Themes group. Copy it, or fix it on purpose and tell Dom.
2. **⌘K order is the CLI's list order**, unsorted, and includes subagent and reminder sessions. Not verified against the live CLI.
3. **Opening a session from ⌘K or the sidebar changes the project filter** to that session's root (`setProject` in `openSession`).
4. **mMac's `Preferences` and `PreferencesPatch` drop both arrays.** The backend already supports them, so M4 is a Swift change plus the UI.
5. **Pins and archives are not shared** between Electron and mMac.
6. **Archive/Restore label follows the sidebar toggle, not the session's real state.** No route to a mismatch was found, so this is a code quirk rather than a visible bug.
7. **An archived session that gets a message stays archived.** There is no unarchive-on-activity rule.
8. **Export format has no dates, no tool arguments, and no `firstUserPrompt` title fallback.** All items, including reasoning, are exported.
9. **Export default folder is unspecified.** The panel's own default applies. Dom should say where mMac's panel starts.
10. **mMac supports two themes**, so the Themes group will have two entries, not five. Needs Dom's confirmation.
11. The conversation `<details>` menu stays open after Pin or Export. An inference from code; confirm in the live app before copying or fixing.

---

## Part 2: composer commands, `@file` mentions, attachments

Source: a read-only survey. File:line references are to the repo at branch `mac-m3`, commit b537661. Read: `src/renderer/src/commands.ts`, `components/Composer.tsx`, `App.tsx` (submit, startNew), `components/Select.tsx`, `components/VoiceInput.tsx`, `styles.css`, `src/main/index.ts` (send, attachments), `src/main/files.ts`, `src/main/muse-host.ts`, `src/preload/index.ts`, `src/shared/protocol.ts`, `src/headless/backend.ts`, `tests/`, and `mac/`.

All paths below are relative to `/Users/dom/Documents/Claude/40-49 Outside Work/42 Muse Desktop/`.

### 0. Summary of what is surprising

- **Drag-and-drop is not an attachment.** Dropping a file on the composer pastes text into the draft: the file's contents in a fenced block, or `@<file name>`. No attachment chip is created, and no IPC is called (`Composer.tsx:241-270`).
- **There is no paste handler.** Pasting an image does nothing special. `grep onPaste|clipboardData src` finds nothing.
- **`@` mentions have no search.** The popup lists one directory (`files` IPC → `listProjectFiles`) and filters it by substring. Nothing resolves the mention before sending: `@path` goes to Muse inside the plain text.
- **Slash commands are all renderer-side.** Only `/compact`, `/model <id>` (open conversation), `/rename <name>`, `/stop` and `/effort <level>` reach main, through the ordinary `compact`, `set-model`, `rename`, `cancel` and `preferences` calls.
- **The headless backend lacks `compact`, `attachments` and `remove-attachment`**, and its `send` rejects any attachment (`attachments: z.array(id).max(0)`, `backend.ts:321`). `tests/unit/headless-parity.test.ts:42-51` lists all three in `notYet`.
- **The M1 survey's section 5 is right about the six commands it lists.** M4 adds `/new`, `/voice`, `/settings`, `/help` (four) and `/stop`, whose full behavior is in section 1.

### 1. Composer slash commands

### 1.1 The list (`src/renderer/src/commands.ts:1-12`)

Order is the menu order. Descriptions are verbatim. The apostrophe in `/stop` is a typographic one (U+2019).

| Name        | Description                                        |
| ----------- | -------------------------------------------------- |
| `/clear`    | `Start a new conversation; keep saved history`     |
| `/new`      | `Start a new conversation`                         |
| `/voice`    | `Start voice input`                                |
| `/model`    | `Choose a model, or /model <model-id>`             |
| `/effort`   | `Choose reasoning effort, or /effort <level>`      |
| `/compact`  | `Compact this conversation with Muse Code`         |
| `/rename`   | `/rename <conversation name>`                      |
| `/stop`     | `Stop Muse’s active turn`                          |
| `/settings` | `Open desktop settings`                            |
| `/help`     | `Open the guide and CLI compatibility information` |

`docs/compatibility.md` (Practical limits) says the composer handles `/clear, /new, /voice, /model, /effort, /compact, /rename, /stop, /settings, and /help`. Other slash commands "explain the CLI handoff without sending them as model messages."

### 1.2 How the popup opens, filters and is navigated (`Composer.tsx:83-85, 173-195, 310-338`)

**Opens when** the whole draft, untrimmed, matches `^\/[a-z-]*$` (case-insensitive). So `/`, `/mo` and `/Model` open it. `/model ` (trailing space), `/model x`, ` /mo` (leading space) and `hi /mo` do not.

**Filter** is a prefix match: `command.name.startsWith(draft.slice(1).toLowerCase())`. List order is kept, there is no cap, and no match means no popup. The menu is `role=listbox`, `aria-label="Composer commands"`, `id="composer-commands"`. Each row is a `role=option` button with `id="command-<name>"`, showing `<strong>/name</strong>` then the description.

**Position and look**: a popup above the composer (`.slash-menu`, `styles.css:3978-3990`: `bottom: calc(100% + 10px)`, full composer width, `max-height: 290px`, scrolls, radius 15). The textarea keeps focus (`onMouseDown` calls `preventDefault`).

**Selection index** (`commandIndex`) resets to 0 on every draft change (`:134-137`). It is not tied to the mouse; a click chooses a row directly.

**Keys while the menu is open and the user is not composing IME text** (`event.nativeEvent.isComposing` is false):

| Key              | Effect                                                                                                                                                                                              |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ↓ / ↑            | Move the index, wrapping at both ends; scrolls the row into view (`block: 'nearest'`)                                                                                                               |
| Tab              | Always chooses the highlighted row: draft becomes `/<name> ` (name, then one space), textarea focused                                                                                               |
| Enter (no Shift) | Chooses the highlighted row, **unless** the draft already equals `/<name>` for some command (compared with `draft.toLowerCase()`), in which case Enter falls through and submits (runs the command) |
| Shift-Enter      | Not intercepted by the menu; falls to the textarea default, a newline (the menu then closes, since `/mo\n` no longer matches)                                                                       |
| Escape           | Sets the draft to `<draft> ` (adds a space), so the menu closes; the draft stays                                                                                                                    |
| Click on a row   | Same as Tab on that row                                                                                                                                                                             |

Consequence: `/m` + Enter fills `/model ` (does not run). `/model` + Enter runs it, even though `/model` also prefix-matches nothing else. `/n` + Enter fills `/new ` (the first of `/new` only, since `/n` matches `/new`). Note `/c` matches `/clear` and `/compact`, in that order.

After a command is chosen the trailing-space draft (`/clear `) closes the menu; Enter then submits it.

### 1.3 Parsing (`commands.ts:14-17`)

```
/^\/([a-z-]+)(?:\s+([\s\S]*))?$/i.exec(text.trim())
→ { name: lowercased, argument: group 2 trimmed, or '' }
```

- Runs on the trimmed draft, so leading and trailing whitespace is ignored. The argument can hold newlines.
- A draft such as `/etc/hosts is odd` does **not** parse (the second `/` is not allowed in the name), so it is sent as an ordinary message. But `/tmp`, `/etc is broken` or `/usr bin` **do** parse as commands and fail with the "not handled" error. A user cannot send a message that starts with `/word`.
- `isCommand = Boolean(parseComposerCommand(draft))` (`Composer.tsx:123`). It lets the Send button stay enabled while disconnected (`!connected && !isCommand`).

### 1.4 What happens on submit (`App.tsx:330-400`)

`submit` runs `setSubmitting(true)` first, so the send button shows a spinner and the Model, Attach and Voice controls disable while a command runs. On any thrown error, `catch` restores the draft if the key's draft is empty and shows an error toast with `showError(message)`. A command's draft is cleared only on success (`:398`), so a failing command leaves the draft in place.

Order of checks, before any command acts:

1. Name not in `composerCommands` throws:
   `` `/${command.name} is not handled by Desktop. Use /help, or open Muse Code in the project inspector for CLI commands.` ``
   (name is lowercased; shown with a leading slash.)
2. Any attachments throws: `Send attachments with a message, or remove them before using a command.`

Then per command (`name`, `argument`):

| Command               | Behavior                                                                                                                                                                                                                                                                                                                                                                                                                                              | Calls                                                                                | Error strings                                                                                                                                                                                                     |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/clear`, `/new`      | `startNew()` (`App.tsx:249-256`): `setPage('chat')`, bumps `openSequence`, clears `activeId`, `setView(null)`, `setLoadingSession(false)`, `setArchived(false)`. Identical for both; the argument is ignored. The old draft key is then cleared. Saved conversations stay.                                                                                                                                                                            | none                                                                                 | none                                                                                                                                                                                                              |
| `/help`               | `setPage('docs')`: shows the Docs page ("Getting started" heading). The composer unmounts.                                                                                                                                                                                                                                                                                                                                                            | none                                                                                 | none                                                                                                                                                                                                              |
| `/settings`           | `setSettings('appearance')`: Settings opens on the Appearance tab                                                                                                                                                                                                                                                                                                                                                                                     | none                                                                                 | none                                                                                                                                                                                                              |
| `/voice`              | no argument: `window.dispatchEvent(new Event('muse:voice'))`; VoiceInput toggles recording (`VoiceInput.tsx:206`). `cancel`: dispatches `muse:voice-cancel`. `status`: success toast. Anything else: error.                                                                                                                                                                                                                                           | none                                                                                 | `Use /voice to record, /voice cancel to discard, or /voice status for help.`                                                                                                                                      |
| `/voice status` toast | `` `Use ${altKey}V to start or stop recording. Muse Code transcribes speech into your draft.` `` with `altKey` = `⌥` on macOS (`Alt+` elsewhere), so on a Mac: `Use ⌥V to start or stop recording. Muse Code transcribes speech into your draft.` (success toast, closes after 4 s)                                                                                                                                                                   | none                                                                                 |                                                                                                                                                                                                                   |
| `/model`              | no argument: dispatches `new CustomEvent('muse:select', { detail: 'Model' })`; the `Select` whose label is `Model` focuses and opens (`Select.tsx:68-74`; ignored when disabled). With an argument: the argument must equal a `modelId` in `models` (exact, case-sensitive). With a view open it calls `setModel(sessionId, argument)`; then `setModelId(argument)` in all cases. With no view, nothing is sent; the id is used by the next `create`. | `set-model` (`muse-host.setModel` → `session/setModel {sessionId, model:{modelId}}`) | `Choose one of the models available in the Model menu.` (also when `models` is empty)                                                                                                                             |
| `/effort`             | no argument: dispatches `muse:select` with detail `'Reasoning effort'`. With an argument: `effortSchema.safeParse(argument.toLowerCase())`. Valid: `savePreferences({ reasoningEffort })`, which persists it for every later message.                                                                                                                                                                                                                 | `preferences`                                                                        | `Choose none, minimal, low, medium, high, xhigh, max, or ultra.`                                                                                                                                                  |
| `/compact`            | needs a view; calls `compact`; toast on result                                                                                                                                                                                                                                                                                                                                                                                                        | `compact` → `session/compact {sessionId}` → `{status}`                               | needs a view: `Open a conversation before using this command.` Toast text: status `noop` gives `There is no conversation history to compact yet.`; any other status gives `Muse is compacting this conversation.` |
| `/stop`               | needs a view; `cancel(sessionId)`                                                                                                                                                                                                                                                                                                                                                                                                                     | `cancel` → `turn/cancel {sessionId}`                                                 | `Open a conversation before using this command.`                                                                                                                                                                  |
| `/rename`             | needs a view. With an argument: `renameSession(sessionId, argument)`. Without: sets the dialog's name field to the current title and opens the Rename dialog.                                                                                                                                                                                                                                                                                         | `rename` (main trims, `min(1)`, `max(200)`; `muse.rename`)                           | `Open a conversation before using this command.` An argument over 200 characters fails Zod, shown through `messageOf` as `Muse could not read this request. Restart the app and try again.`                       |

Notes:

- Commands do not check the connection. They run while disconnected, but the ones that call main then fail with whatever error main gives.
- `/model` and `/effort` do not mention the running state; both work mid-turn. `/effort` takes effect on the next `send`, which carries `effort`.
- `/clear` and `/new` do not reset the composer's attachments or queue/steer mode in Electron (the mode is Composer-local); mMac's `Workspace.startNew()` resets `mode`, which differs slightly. Not important.
- `/compact` and `/rename` do not clear the view's items; the `session/nameChanged` and compaction events do the rest.
- Success toasts use `showSuccess`: `role=status`, auto-close 4 s. Errors use `showError`: `role=alert`, stay until dismissed ("Dismiss notification").

### 1.5 Backend support for commands

| Needs                                                    | Headless backend today                                                                                                                                                                                                                                                                                                                                                                                                       |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `set-model`, `rename`, `cancel`, `preferences`, `models` | Present (`backend.ts:337-353`) and wrapped by `MuseBackend/Methods.swift` (`setModel`, `rename`, `cancel`, `preferences`, `models`)                                                                                                                                                                                                                                                                                          |
| `compact`                                                | **Missing.** `MuseHost.compact` exists (`muse-host.ts:349-355`) and `tests/unit/muse-host.test.ts:237-251` covers it. Add `method('compact', …)` that does `sessionProject(id)` then `muse.compact(id)` (Electron: `index.ts:555-559`), plus a `compact(sessionId:)` Swift client call returning `{status: String}`. Update `headless-parity.test.ts` (move `'compact'` out of `notYet`, adjust the `headless` count of 36). |
| Slash menu, parsing, prefix filter, command table        | Pure UI logic: port `commands.ts` into MuseKit as a testable type                                                                                                                                                                                                                                                                                                                                                            |
| `/voice`                                                 | UI-only in Electron; mMac needs its own voice work                                                                                                                                                                                                                                                                                                                                                                           |
| `/help`                                                  | Electron shows the Docs page (`DocsPage`). **mMac has no docs page.** Decision for Dom: open the compatibility notes or `https://dev.meta.ai/docs/muse-code` (the URL `MuseCodePane.swift:76` already uses)                                                                                                                                                                                                                  |
| `/settings`                                              | mMac has a `Settings` scene (`MMacApp.swift:81`) with an Appearance pane; open it as the ⌘, command does                                                                                                                                                                                                                                                                                                                     |

### 1.6 What mMac has today

- `mac/mMac/ComposerView.swift:6` says "without attachments, voice and slash commands (M4)". The text view has no menu, and Tab moves focus (`ComposerTextView.swift` `insertTab` / `insertBacktab` override), so the slash and mention menus need their own Tab handling.
- `ComposerTextView.keyDown`: Return, keypad Enter and ⌘-Return send; Shift, Option and Control Return insert a newline; marked text (IME) is respected. This matches Electron's Enter behavior. Arrow, Escape and Tab for the popups are missing.
- Reusable actions in `Workspace`: `startNew()` (`Workspace.swift:347`), `chooseModel(_:)`, `chooseEffort(_:)` (saves preferences), `stop()`, `rename(_:)` (trims; blank returns false), `draft`, `models`, `mode`, `errorMessage`. `RenameSheet` exists in `ConversationView.swift:83`; its `renaming` state is local to the view, so `/rename` with no argument needs a way to raise it.
- `Workspace.send` sets `errorMessage` on failure and restores the draft; Electron shows the same error as a toast. mMac has no success toast; `/compact` and `/voice status` need one.
- No tests for commands anywhere in `mac/`.

### 1.7 Edge cases to keep

- Matching is case-insensitive for names and efforts, but `/model <id>` is exact and case-sensitive.
- `/effort` ignores the model's `reasoningEffortVariants`; any of the eight values is accepted.
- `/model x` with an open view sets the model on the session first; `modelId` changes only after `setModel` succeeds in Electron's slash path (`await` before `setModelId`), but the Select path (`setModel`, `App.tsx:467-479`) also waits for success.
- A command in a draft with a newline in its argument: `/rename a\nb` renames to `a\nb`.
- The menu does not open if `project` is missing or any other state; only the draft matters.
- Typing `/` then deleting leaves no residue.

### 1.8 Tests

- `tests/e2e/desktop.spec.ts:312-336` ("composer commands control the app without becoming model messages"): `/effort medium` (combobox shows `Medium`), `/plugins` (alert contains `not handled by Desktop`, no user message), `/clear` (transcript empties, draft empty), `/vo` shows the voice option, Tab fills `/voice `, Enter starts recording (`Stop recording (⌥V)`), Cancel clears.
- `tests/e2e/desktop.spec.ts:226-257` covers voice.
- `tests/unit/muse-host.test.ts:237-251` covers `compact`.
- No unit test for `parseComposerCommand`, `/model`, `/rename`, `/stop`, `/compact` toasts, `/settings`, `/help`, or the keyboard rules.

### 2. @file mentions

### 2.1 When the popup opens (`Composer.tsx:86-122`)

- Only when a `project` is set (the Composer's `project` prop; empty means no mentions).
- Match: `/(?:^|\s)@([^\s@]*)$/` against the **whole draft**. The `@` must start the draft or follow whitespace, and the token must run to the end of the draft. The cursor position is ignored, so typing `@` in the middle of the text does nothing.
- `mentionToken` is the text after the `@`. If it holds `/`, `mentionDir` is the part before the last `/` and the filter is the part after it; otherwise `mentionDir` is `''` and the filter is the whole token.
- The filter is `entry.name.toLowerCase().includes(filter.toLowerCase())` (substring, on the file name only, not the path). Results are cut to the first **12**.

### 2.2 Where the entries come from

- `window.muse.listFiles(project, mentionDir)` → IPC `muse:files` → `listProjectFiles(project, directory)` (`src/main/files.ts:14-29`). Main requires the project to be known (`knownProject`, `index.ts:263-285`).
- `listProjectFiles` lists **one directory level**. It resolves with `realpath` and rejects paths outside the project (`This path is outside the selected project.`). It drops `.git`, `node_modules`, `.DS_Store` and every symbolic link. It keeps other dotfiles. Order: directories first, then `localeCompare` on name. Each entry is `{name, path, directory}` where `path` is relative to the project root with `/` separators.
- The effect re-runs when `project`, `mentionDir`, or whether a mention is active changes (`:99-116`), **not** on each typed character, so filtering is local on the cached listing. It ignores stale results (`cancelled` flag).
- Failures (unknown project, missing directory) clear the list silently. No error is shown.
- `Escape` empties the list (`setMentionFiles([])`). Because the effect's dependencies do not change, typing more characters does **not** bring the menu back until the mention ends or `mentionDir` changes.

### 2.3 The menu and keys (`Composer.tsx:196-219, 339-363`)

- `role=listbox`, `aria-label="Project files"`, `id="composer-mentions"`, class `slash-menu mention-menu`. Each row is a `role=option` button, `id="mention-<path>"`: a `Folder` or `FileCode2` icon (14 px), `<strong>path</strong>`, then the word `Folder` or `File`. It sits above the composer like the slash menu.
- Keys: ↓/↑ move with wrap and scroll into view; Tab, or Enter without Shift, chooses; Escape closes. Click chooses. The textarea keeps focus.
- The slash menu is checked first, but the two cannot both be open (a draft that is only `/word` has no `@`).
- Note there is no `aria-activedescendant` on the textarea for mentions (only for commands).

### 2.4 Insertion (`:128-133`)

```
prefix = draft up to the "@"; draft = prefix + "@" + entry.path + (entry.directory ? "/" : " ")
```

- A file adds a trailing space, which ends the mention. A folder adds `/`, which keeps the menu open in that folder (`mentionDir` becomes the folder). Paths containing spaces are inserted unquoted, so the token breaks at the space.
- The inserted text is the **project-relative path**, even when the user filtered from a subfolder.

### 2.5 How a mention reaches Muse

- Nothing special. The `@path` stays in `text`, and `send` puts that text in the first part `{type:'text', text}`. Main does not read, resolve, or expand mentions (`index.ts:560-617`).
- **Ambiguous**: whether the Muse Code CLI itself expands `@path` in a user message is not visible from this repo. The "Ask Muse" on a diff sends `Please review the changes in @<path>` (`mac/.../Workspace+Actions.swift:239` copies it), which suggests the CLI understands it, but I found no proof. Treat the mention as plain text and test against a real model before M4 claims parity.
- `askAboutFile` (Electron `onMention`) writes `Please look at the project file: "<path>"` (JSON string) instead.

### 2.6 Backend support and mMac

- `files` is already in the headless backend (`backend.ts:408-410`, with `knownProject`, input `z.string().max(4096)`), tested at `tests/unit/headless-backend.test.ts:632-650`, and wrapped by `MuseBackend/Methods.swift:139` (`files(project:directory:)`, returning `ProjectFile`). **No backend change is needed for mentions.**
- mMac's `Inspector` already lists a directory with the same call (`Inspector.swift:330`) and filters by `name.lowercased().contains(needle)` (`:135`). A composer version can reuse `ProjectFile`.
- No mention UI exists in mMac.
- Tests: none for the composer menu (no e2e or unit). `tests/unit/files.test.ts` covers `listProjectFiles` (sorting, symlink exclusion, nested paths). `tests/e2e/desktop.spec.ts:259-277` covers only the Files page and "Ask Muse".

### 3. Attachments

### 3.1 The paperclip (`Composer.tsx:159-170, 372-380`)

- Icon button `Paperclip`, label `Attach images or text files`, disabled while `submitting`. It is not disabled when disconnected or while running.
- `attach()` calls `window.muse.chooseAttachments()` (IPC `attachments`). If `attachments.length + files.length > 5`, it calls `removeAttachment` for every new id and throws `You can attach up to five files per message.` Otherwise it appends the new chips. Any thrown error goes to `onError` (error toast).

### 3.2 Main's `attachments` handler (`src/main/index.ts:645-667`)

- `dialog.showOpenDialog(window, { title: 'Add context to your message', properties: ['openFile', 'multiSelections'] })`. No file-type filter. Cancel returns `[]`.
- More than 5 paths: throws `Select up to five files at a time.`
- For each path: `stat`. If it is not a regular file or `size > 2 MB` (2·1024·1024), it throws `` `${basename(path)} must be a file smaller than 2 MB.` ``. The check is per file and in order, so earlier files in the same call are already registered in `selectedFiles` and never returned (a small leak).
- Each accepted file becomes `{ id: randomUUID(), name: basename(path), kind: /\.(png|jpe?g|webp|gif)$/i.test(path) ? 'image' : 'text', size }`. The map `selectedFiles: Map<id, {attachment, path}>` (`index.ts:86`) is memory-only in main. The renderer only holds `{id, name, kind, size}`.
- `kind` comes from the extension alone. A PDF, ZIP or `.heic` is `text`; it fails later at send.
- `remove-attachment(id)` (`:668-670`) deletes the map entry. The renderer does not wait for it (see chips).

### 3.3 Chips (`Composer.tsx:276-297`, `styles.css:1299-1331`)

- A flex-wrap row above the textarea, gap 6 px. Each chip: a bordered, 6 px radius, `soft-surface` pill, max width 200 px, with an `Image` or `FileText` icon (14 px), the file name (single line, ellipsis), and an `X` button (12 px) labelled `` `Remove ${file.name}` ``.
- No size, no thumbnail, no error state.
- Remove: calls `removeAttachment(id)` and removes the chip from state at once; a rejected call shows a toast with the error message.
- Attachments are `useState` in the Composer, so they persist while the user switches conversations (the Composer is not remounted) but vanish when the Composer unmounts, for example on `/help` or the Docs page. `docs/compatibility.md` says "Attachment selections belong to the current composer and are temporary."
- The Send button enables when the draft has text **or** at least one attachment (`:457-462`), so a message can be attachments only.
- After a successful `submit` the list is cleared (`setAttachments([])`, `:157`). On failure the chips stay.

### 3.4 What `send` does (`src/main/index.ts:560-617`)

Input (Zod): `{sessionId, text ≤ 200000 chars, attachments: ≤ 5 ids, effort, mode}`. Steps, in order:

1. Empty text and no attachments: `Write a message or attach a file first.`
2. `sessionProject(sessionId)` (trust check).
3. `parts = [{type:'text', text}]`; `bytes = Buffer.byteLength(text)`.
4. For each id, in order:
   - Unknown id: `An attachment expired. Select it again.`
   - `stat(path).size > 2 MB`: `Attachments must be 2 MB or smaller.`
   - `data = readFile(path)` (read now, not at attach time); `bytes += data.length * 1.4`; if `bytes > 4 MB` (4·1024·1024): `This message exceeds the 4 MB attachment limit.` The 1.4 factor stands for base64 growth and applies to text files too.
   - Image: `{type:'image', mediaType, base64Data: <base64 of the whole file>}`. `mediaType` comes from the extension (case-insensitive): `.png` `image/png`; `.jpg` and `.jpeg` `image/jpeg`; `.webp` `image/webp`; `.gif` `image/gif`. No resizing, no re-encoding, no validation of the bytes.
   - Text: if the data contains a NUL byte: `` `${name} is a binary file. Attach an image or a text file.` ``. If `data.length > 200 KB` (200·1024): `Text attachments must be 200 KB or smaller.` Otherwise `{type:'text', text: 'Attached file: ' + name + '\n\n' + data.toString('utf8')}` (invalid UTF-8 becomes U+FFFD; a BOM is kept).
5. `displayText = [text, ...names.map(n => '[Attached: ' + n + ']')].join('\n')`. With empty text this starts with a newline.
6. `muse.send(sessionId, parts, effort, mode, displayText)` → `turn/start {sessionId, input: parts, displayText, reasoningEffort: effort, ifBusy: mode}` (`muse-host.ts:331-346`, `maxAttempts: 1`).
7. Only on success: the used ids are deleted from `selectedFiles`. On any error the ids stay valid so the renderer can retry.

The limits as the docs state them: five files, 2 MB each, 200 KB per text file, about 4 MB per message including encoded image data (`docs/compatibility.md`, Practical limits).

Renderer side (`App.tsx:451-457`): `attachments: attachments.map(f => f.id)`. The optimistic transcript item shows only `text`, not the `[Attached: …]` lines; the next session event replaces it with the CLI's item (which carries `displayText`).

### 3.5 Drag and drop (`Composer.tsx:232-270`)

- Target: the `<form className="composer">` only. There is no window-level drop zone; `will-navigate` is blocked in main (`index.ts:786`), so a drop elsewhere does nothing.
- `onDragOver`: `preventDefault`, sets `dragging`. `onDragLeave`: clears it unless the pointer moved to a child. `onDrop`: `preventDefault`, clears it. The `is-dragging` class changes the border to the focus color and adds a 3 px `focus-soft` ring (`styles.css:3956-3961`). No text, no type filter on the drag.
- On drop, for the first **5** files (`dropped.slice(0, 5)`; the rest are ignored silently):
  - If `file.size <= 120 * 1024` **and** the name does not match `/\.(png|jpe?g|webp|gif|pdf|zip)$/i`: read it with `file.text()` (UTF-8, lossy). If the text contains `\0`, or reading throws (a folder throws), fall back to the name reference. Otherwise add ` ```<file.name>\n<content.trim()>\n``` ` (backticks in the content are not escaped, and the fence has no language).
  - Anything else (an image, a PDF, a zip, a file over 120 KB, a binary, a folder) adds `@<file.name>`: the base name, not a path. For a file outside the project, Muse cannot resolve it.
- The additions are appended to the **latest** draft (`latestDraft` ref): `current + (current && !/\s$/.test(current) ? '\n' : '') + additions.join('\n') + '\n'`; the textarea then takes focus.
- Dropped files are never added to `attachments`, never limited by the 2 MB / 4 MB rules, and never sent as image parts. Dropping an image is therefore weaker than clicking the paperclip.
- Dropping text counts toward the 200000-character `text` limit only.

### 3.6 Paste

Electron has no handling at all: no `onPaste`, no `clipboardData` use. Pasting an image into the textarea inserts nothing (the browser default for a non-text clipboard); pasting text pastes text. The compatibility doc lists no paste support. **Do not add paste of images in mMac if parity is the goal;** raise it as a separate enhancement.

### 3.7 Backend support: what is needed

`src/headless/backend.ts:315-335` today accepts text only, with `attachments: z.array(id).max(0)` and the error `Write a message first.` (Electron: `Write a message or attach a file first.`). `MuseBackend/Methods.swift:62-70` hardcodes `"attachments": []`. The wire has no dialog (`attachments` shows `showOpenDialog`), and the design spec says "the app shows the native panel and sends the chosen path. The backend validates it as today" (`docs/superpowers/specs/2026-10-21-mac-app-design.md`, table row "Project, CLI, attachment and export pickers").

Smallest change that keeps parity and the existing test seam:

1. Move the attachment code in `index.ts:560-617, 645-670` into a shared module (for example `src/main/attachments.ts`) that exports `registerAttachments(paths)` (the per-file stat checks and `kind` rule), `removeAttachment(id)`, and `buildParts(text, ids)` (steps 3-5 above, returning `{parts, displayText}`). Both `index.ts` and `backend.ts` call it, so the strings stay identical.
2. New headless method `attachments(paths: string[])`: ≤ 5 paths (`Select up to five files at a time.`), then per-file checks as in 3.2; returns `Attachment[]`. mMac runs `NSOpenPanel` (multi-select, files only, title `Add context to your message`) and sends the paths. This keeps the `selectedFiles` map in the backend, so a later `send` finds the ids.
3. New method `remove-attachment(id)`.
4. `send`: change `max(0)` to `max(5)`, the empty check to `!text.trim() && !attachments.length` with the Electron string, call `buildParts`, then delete the used ids after a successful send.
5. Swift: `attachments([URL])`, `removeAttachment(_:)`, and `send(... attachments: [String])` in `Methods.swift`; an `Attachment` model (`id`, `name`, `kind`, `size`) in `Models.swift`.
6. Tests: update `headless-parity.test.ts` (`notYet` loses `attachments` and `remove-attachment`; the `headless` count of 36 grows by two, plus `compact`); rewrite "sends text only, after the trust check" (`headless-backend.test.ts:245-260`), which currently expects `attachments: ['a1']` to be rejected; add cases for each error string in 3.4.

An alternative, a `send` that takes paths directly with no ids, would drop the "expired" case but changes the wire shape from Electron's. I would not do it.

### 3.8 What mMac has

- `ComposerView.swift` has no attach button, chips, or drop target; `Workspace.send(text:from:)` takes text only and the draft is a `String`. The optimistic item shows `text` for both `text` and `displayText`.
- `NSOpenPanel` helpers: `AppController.chooseProjectFolder` and `SheetAlert.run(_:)` (a sheet on the key window). An attachment picker can reuse `SheetAlert.run`, but it returns one `URL?`; multi-selection needs a variant.
- Drag-and-drop: SwiftUI `dropDestination(for: URL.self)` or `onDrop` would carry real paths, unlike Electron's name-only fallback. To match Electron, send `@<last path component>` for the fallback, or decide that a real path is better (a product choice, not parity).
- Draft state: `Workspace.drafts[draftKey]`. Attachment chips should live next to the composer, not in `drafts`, to match Electron (not per session).

### 3.9 Edge cases to keep

- The 4 MB budget counts the text and 1.4 times each file's raw bytes, text files included. With the 2 MB per-file cap, two 1.5 MB images exceed the budget (2 × 1.5 × 1.4 = 4.2 MB).
- Non-image files that are not text are rejected only at send time, with the draft kept and chips kept.
- A file that grows past 2 MB, or is deleted, between attach and send fails at send (`stat` error for a deleted file is the raw `ENOENT` message).
- Duplicates are allowed: the same file attached twice makes two chips and two parts.
- The first `onSubmit(true)` clears chips even if the session event arrives later.
- A conversation switch keeps chips; sending them into a different conversation is allowed.
- Slash commands refuse any chips (see 1.4).

### 3.10 Tests

- None in `tests/e2e` or `mac/` for attachments, paste, drag-and-drop, or mentions.
- Related: `tests/unit/headless-backend.test.ts:245-260` ("sends text only, after the trust check") and `tests/unit/headless-parity.test.ts:42-51` (`notYet`), `tests/unit/muse-host.test.ts` (forwards queue and steer modes: the `turn/start` shape), `tests/unit/files.test.ts` (project file listing).

### 4. Port checklist for M4

1. `compact` method (backend and Swift client).
2. Attachment methods and the `send` change (3.7); parity test updates.
3. MuseKit: a `ComposerCommand` table and `parse` with the exact regex and strings above; the prefix filter; the Enter/Tab rules from 1.2; unit tests for each error string.
4. MuseKit: the mention matcher (`(?:^|\s)@([^\s@]*)$` on the whole draft), directory/filter split, 12-row cap, and insertion rules; reuse `client.files`.
5. SwiftUI: two popups above the composer (command list, mention list), key handling in `ComposerNSTextView` (Up, Down, Tab, Enter, Escape) with Tab no longer moving focus while a menu is open.
6. Success and error toasts for commands (mMac has only `errorMessage`).
7. Open points for Dom: `/help` target (no docs page in mMac); whether the CLI expands `@path` (test with a real model); whether drop should send real paths.

---

## Part 3: voice input, the open-in actions, the size baseline

Read-only survey. Repo: `/Users/dom/Documents/Claude/40-49 Outside Work/42 Muse Desktop`, branch `mac-m3`, HEAD `b537661`. Paths below are relative to that repo. Nothing was built, launched or edited. I read no file under `~/.config/muse/`. The only file I read outside the repo is the launcher script `~/.local/bin/muse` (to look for voice strings; there are none).

---

### 1. Voice input

### 1.1 How transcription works (the answer)

- It is **none of the usual options**. Desktop does not use the Web Speech API, a local model, or a cloud API of its own. It has **no API key and stores no credential**.
- Desktop writes the recording to a private temp WAV file and runs the user's own Muse Code CLI: `muse voice transcribe <file.wav>`. The text printed on stdout (trimmed) becomes the draft text. (`src/main/voice.ts:59-66`)
- Authentication and the speech service belong to the CLI. The CLI's login is `muse login`. Its launcher uses Meta's device-code flow at `auth.meta.com`, with the token in `~/.config/muse/auth.json`. The repo never names the service that does the speech-to-text. `docs/compatibility.md:43` says only: "Audio may be sent to the service configured by Muse Code; this is not offline transcription."
- The CLI must support the `voice transcribe` subcommand. Older CLIs fail with a mapped message (see 1.6). The repo cannot tell us which CLI version added it. The SDK in `node_modules/@muse-code` has no "voice" string.
- **Ambiguity:** I did not run `muse voice --help` (it would read the user's config and credentials). Which backend the CLI uses, what languages it supports, and whether stdout is plain text are known only from Desktop's code: it takes stdout as plain text, and `maxBuffer` is 256 KiB.

### 1.2 Capture and audio format (renderer, `src/renderer/src/components/VoiceInput.tsx`)

- Microphone: `getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true }, video: false })` (`:79-82`).
- Recorder: `MediaRecorder(stream, { mimeType: 'audio/webm;codecs=opus' })`, `start(250)` so chunks arrive every 250 ms (`:88`, `:135`). A recorder error shows "The microphone stopped recording. Check your input device and try again." and cancels (`:94-99`).
- On stop, the chunks become one Blob, `AudioContext.decodeAudioData` decodes them, and `encodeVoiceWav(channels, audio.sampleRate)` makes the file (`:100-117`).
- `encodeVoiceWav` (`src/shared/voice.ts:6-41`): **mono, 16 kHz, 16-bit signed PCM WAV**, 44-byte header. All channels are averaged to mono. Resampling is a plain box average over each output sample's source span. No filter. Samples are clamped to [-1, 1], then scaled by 32768 (negative) or 32767 (positive).
  - Source rate below 16000 Hz or not finite: "The microphone returned an unsupported audio format."
  - Fewer than 3200 samples (0.2 s): "Record at least a moment of speech and try again."
  - More than 1,920,000 samples (120 s): "Voice recordings can be up to two minutes."
- Constants (`src/shared/voice.ts:1-3`): `VOICE_SAMPLE_RATE = 16000`, `MAX_VOICE_SECONDS = 120`, `MAX_VOICE_BYTES = 44 + 16000*120*2 = 3,840,044`.

### 1.3 Main-process code

- `src/main/voice.ts`
  - `validateVoiceAudio(value)` (`:7-32`): needs a `Uint8Array` of 6444 to 3,840,044 bytes (else "Record between a moment and two minutes of speech."). Then it checks the whole header: RIFF, WAVEfmt, size fields, PCM (1), mono (1), 16000 Hz, byte rate 32000, block align 2, 16 bits, `data` chunk, even byte count. Any mismatch gives "The recording is not a supported PCM audio clip. Please record it again."
  - `VoiceTranscriber.transcribe(value, cliPath)` (`:43-98`):
    1. Validate the audio.
    2. Refuse a second call while one runs: "A voice recording is already being transcribed."
    3. `discoverCli(cliPath)`. **This runs a login shell (`$SHELL -ilc`, 6 s limit) and `muse --version` on every transcription**, because it re-discovers the CLI rather than using `muse.status`. Discovery errors, such as "Muse Code was not found. Install the CLI, run muse login in Terminal, then reconnect.", pass through unmapped.
    4. `mkdtemp(os.tmpdir()/muse-desktop-voice-XXXXXX)`, write `recording.wav` with mode 0600.
    5. `execCli(cli.path, ['voice','transcribe',path], { env: cli.environment, signal, timeout: 90_000, maxBuffer: 256*1024, encoding:'utf8' })`. No `cwd` is set (the Electron process's own). The environment is the login-shell environment plus the augmented PATH, with `ELECTRON_RUN_AS_NODE` and `NODE_OPTIONS` deleted (`src/main/cli.ts:70-73`).
    6. Empty stdout gives "No speech was detected. Try recording again, closer to your microphone."
    7. `finally`: delete the temp directory, clear `active`.
  - `cancel()` (`:38-41`): abort the controller, then wait for the child and cleanup to finish.
- `src/main/index.ts`: `const voice = new VoiceTranscriber()` (`:210`); `handle('microphone', ...)` (`:378-386`); `handle('voice', (audio) => voice.transcribe(audio, preferences.cliPath))` (`:387`); `handle('cancel-voice', () => voice.cancel())` (`:388`); `voice.cancel()` joins the quit path (`:940`).
- IPC: `muse:microphone`, `muse:voice`, `muse:cancel-voice` (`src/preload/index.ts:49-51`; types `src/shared/protocol.ts:304-306`).

### 1.4 Permissions

- Renderer asks main first: `await window.muse.requestMicrophone()` (`VoiceInput.tsx:77`). Main calls `systemPreferences.askForMediaAccess('microphone')` on macOS (`index.ts:378-386`). If denied it throws: **"Microphone access is off. Enable Muse Desktop in System Settings → Privacy & Security → Microphone."** If granted it sets `microphoneEnabled = true`.
- `microphoneEnabled` gates Chromium's own prompt: `setPermissionRequestHandler` and `setPermissionCheckHandler` (`index.ts:788-808`) allow only `media` with audio only, from the main frame of the app window, once the flag is true.
- If `getUserMedia` still throws `NotAllowedError`, the same "Microphone access is off..." string shows (`VoiceInput.tsx:173-175`). Any other error shows its own message, or "Could not start your microphone."
- Packaging (`electron-builder.yml:23-26`, `resources/entitlements.mac.plist`):
  - `NSMicrophoneUsageDescription`: **"Muse Desktop records your voice only when you start voice input, then uses your Muse Code CLI to transcribe it into a draft."**
  - Entitlements: `com.apple.security.cs.allow-jit` and `com.apple.security.device.audio-input`. Hardened runtime is on.
- **mMac today:** `mac/mMac/Info.plist` and `mac/project.yml` have **no `NSMicrophoneUsageDescription`**. There is no entitlements file, and hardened runtime is off (`project.yml: ENABLE_HARDENED_RUNTIME: NO`), the app is not sandboxed, and it is signed ad hoc. Without the usage-description key, macOS ends the process the first time the app touches the microphone. The key must go into both files (`project.yml` writes Info.plist). The audio-input entitlement matters only if hardened runtime is turned on later. Ad-hoc re-signing changes the code identity on each rebuild, so macOS may ask for microphone consent again after rebuilds.

### 1.5 UI, states and every string

Where: the composer toolbar, after the paperclip and a divider, before the Model select (`Composer.tsx:382-391`). `disabled={submitting || !connected}`.

Phases (`VoiceInput.tsx:6`): `idle`, `permission`, `recording`, `transcribing`. There is no separate error phase: an error goes to the app's error toast (`onError`) and the phase returns to idle.

| Phase        | Button                                                                                       | Status pill                                                                |
| ------------ | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| idle         | Mic icon (17), label **"Voice input (⌥V)"**, disabled when `disabled`                        | none                                                                       |
| permission   | spinner, button disabled                                                                     | **"Opening microphone…"**                                                  |
| recording    | filled Square icon (15), label **"Stop recording (⌥V)"**, active (pressed), colour `#e85d6f` | waveform + **"Listening · M:SS"** (`Math.floor(s/60)` : two-digit seconds) |
| transcribing | spinner, button disabled                                                                     | **"Transcribing with Muse…"**                                              |

- In every non-idle phase the pill (`role="status"`) shows above the button: absolute, `bottom: calc(100% + 10px)`, rounded 12, border, `--dialog` background. It holds the optional waveform, the text, and a small X button, label **"Cancel voice input"**.
- "⌥" is shown on macOS; `App.tsx:139` uses "Alt+" elsewhere.
- Waveform (`:138-165`, CSS `styles.css:3938-3951`): 5 bars, each 2.5 px wide, 14 px tall, `#e85d6f`, `transform: scaleY(level)` with a 0.1 s ease. Levels start at `[0.25, 0.45, 0.35, 0.5, 0.3]`. A second `AudioContext` feeds an `AnalyserNode` (`fftSize = 32`, so 16 bins). Every 120 ms the bars take byte-frequency bins 1 to 5, divided by 180, clamped to [0.22, 1]. If metering fails the bars stay at the starting levels (comment: "optional visual polish").
- The timer runs every 120 ms and shows whole seconds since start.
- **Limit:** the recorder stops itself when `elapsed >= MAX_VOICE_SECONDS - 1`, so about 119 s ("Leave room for the final encoder frame before the two-minute limit", `:163-164`). Then it transcribes as normal.

Triggers:

- Click the mic button toggles: start, or stop and transcribe.
- **Option-V**, window-wide (`:181-198`): `event.altKey && !metaKey && !ctrlKey && event.code === 'KeyV' && !event.repeat` and no `dialog[open]` in the document. It toggles. It uses the physical key code, so a keyboard layout cannot change it.
- **Escape**, when busy (phase is not idle), cancels.
- `document.hidden` while busy cancels (window minimised or hidden; `:199-201`).
- Composer slash command `/voice` (list entry "Start voice input", `commands.ts:4`). `App.tsx:348-361`:
  - `/voice` dispatches the window event `muse:voice` (toggle).
  - `/voice cancel` dispatches `muse:voice-cancel`.
  - `/voice status` shows the success toast **"Use ⌥V to start or stop recording. Muse Code transcribes speech into your draft."**
  - Any other argument throws **"Use /voice to record, /voice cancel to discard, or /voice status for help."**
  - After any command the draft is set to `''` (`App.tsx:398`), so the command text is not left in the composer. A command with attachments is rejected first: "Send attachments with a message, or remove them before using a command."
- While voice is busy, the Send button is disabled and `submit()` returns early (`Composer.tsx:151`, `:458`). A recording never auto-sends.

Cancel (`:41-50`): bump a generation counter (so late async results are ignored), stop the recorder, release the stream, timer and meter, clear busy, set idle, and call `cancelVoice()` in main. A cancel shows no message. Unmount does the same (`:51-64`).

How text lands in the draft (`Composer.tsx:386-390`): `existing = latestDraft.current`; new draft = `existing + (existing && !/\s$/.test(existing) ? ' ' : '') + text`; then the textarea is focused. It **appends at the end** of the draft (not at the caret), with one separating space when needed, and keeps the draft unsent. The e2e test expects `"Existing draft. A voice draft to review."`.

### 1.6 Error strings (all verbatim, main side `voice.ts`)

- Timeout or other kill (`failure.killed`): "Voice transcription timed out. Check your connection and try again."
- stderr matches `/unauth|login|sign.in|credential|401|403/i`: "Muse voice needs authentication. Run muse login in Terminal, then try again."
- stderr matches `/unrecognized|unexpected|unknown (command|subcommand)/i`: "This Muse Code version does not support voice transcription. Update your CLI and reconnect."
- Any other stderr: "Muse Code could not transcribe this recording. Check your connection and CLI voice setup, then try again."
- Aborted (cancel or quit): "Voice transcription cancelled." (the renderer never shows it, because cancel changes the generation first).
- **Ambiguous / worth a decision:** a non-zero exit with empty stderr and no kill is rethrown as the raw `execFile` error. Its text begins "Command failed: ..." and includes the command line, hence the temp path. The comment at `:76` says paths are kept out of messages, but this branch does not.

### 1.7 Does `src/headless/backend.ts` have an equivalent?

No. `voice` and `cancel-voice` are in the parity test's `notYet` list (`tests/unit/headless-parity.test.ts:41-43`). The spec says "bridges, voice, prefs" live in the backend (`docs/superpowers/specs/2026-10-21-mac-app-design.md:34`) and row 75 says the app records 16 kHz mono WAV and "sends it to the existing transcribe method".

What is needed:

- `method('voice', ...)` calling `VoiceTranscriber.transcribe(audio, current().cliPath)`. `src/main/voice.ts` has no Electron imports (only `./cli` and `../shared/voice`), so the backend can import it unchanged (like `src/main/muse-host.ts`).
- `method('cancel-voice', ...)` calling `voice.cancel()`, and `voice.cancel()` in the `shutdown` path (`backend.ts:501`), as `index.ts:940` does.
- **How to carry the audio.** The wire is one JSON line per message (`src/headless/wire.ts`), so a `Uint8Array` cannot cross as is. Options: (a) base64 string, about 5.1 MB for the longest clip, decoded to a `Buffer` (a `Uint8Array`, so `validateVoiceAudio` accepts it); (b) mMac writes the WAV to a private temp file and sends the path, as the M3 notes describe for attachments, and the backend reads and validates it. I did not check any line-length limit in `server.ts` or `Transport.swift`; check before choosing (a). `requestSchema` caps `args` at 10 items but sets no size limit.
- Update `electron`/`headless` counts in the parity test (`toHaveLength(53)`/`(36)`, `:51-52`) and remove `voice`, `cancel-voice` from `notYet`. `microphone` is already `electronOnly` ("mMac asks macOS for the microphone").
- The Swift client, `mac/Packages/MuseBackend/Sources/MuseBackend/Methods.swift`, has no voice call; add `voice(_:)` and `cancelVoice()`.

### 1.8 mMac already has

Nothing for voice. `ComposerView.swift:6` says "without attachments, voice and slash commands (M4)". Hits for "voice" in `mac/` are VoiceOver comments only. Relevant existing pieces:

- `ComposerTextView.swift` handles Return, Shift-Return and Option-Return (`:5`). Option-V would type "√" in a plain text view, so intercept it (`keyCode 9` with Option only), or use a menu command with the Option modifier. Electron's shortcut is window-wide, also when the composer lacks focus.
- `Workspace.draft` is the draft binding (`ComposerView.swift:23`). Append to it as in 1.5.
- Toast/error surface: `settings.errorMessage` exists for Settings; check how `ComposerView` reports errors before choosing.

### 1.9 macOS-native options (note only)

- `AVAudioEngine` (input node tap, `AVAudioConverter` to 16 kHz mono Float32 or Int16) can produce the exact WAV and also the level meter (RMS per 120 ms), with no WebM decode step. `AVAudioRecorder` with Linear PCM settings (16000 Hz, 1 ch, 16-bit) writes the WAV directly.
- Permission: `AVCaptureDevice.requestAccess(for: .audio)` (or `AVAudioApplication.requestRecordPermission`), plus `NSMicrophoneUsageDescription`.
- `SFSpeechRecognizer` would be a different transcriber (on-device or Apple servers; needs `NSSpeechRecognitionUsageDescription`). It would not match Desktop, which uses the CLI.

### 1.10 Tests covering voice

- `tests/unit/voice.test.ts`: stereo downmix and resample to a valid 16 kHz WAV (value 16384 from 0.75 and 0.25), clipping to -32768, short clip rejected ("at least"), oversize rejected ("two minutes"), non-PCM header rejected ("PCM"), non-Uint8Array rejected.
- `tests/e2e/desktop.spec.ts:226-256`: simulated recording with Alt+V, "Stop recording (⌥V)", status shows "0:01", second Alt+V inserts `"Existing draft. A voice draft to review."`, no user message sent, then cancel via "Cancel voice input". `:326-336`: `/vo` suggests `voice`, Tab gives `/voice `, Enter starts recording, cancel clears the draft. The e2e mocks `muse:voice`, so the real `muse voice transcribe` call is not in any test here (the comment says it was "verified separately with synthetic speech"; I found no script for it).
- No test covers `execCli` for voice, the error mapping, the 90 s timeout, or cancel while transcribing.

---

### 2. Open the project in Finder, Terminal, or full Muse Code CLI

### 2.1 Where it appears

Only in the **Project inspector footer** (`src/renderer/src/components/Inspector.tsx:486-513`), below the usage panel. Three plain text buttons, left to right, `justify-content: space-between`, 12 px / 18 px padding, `--muted` colour, `--text` on hover (`styles.css:2282-2297`). No tooltips (`title`), no menu-bar item, no context menu, no toolbar button, no keyboard shortcut. The File menu has only "New conversation", "Open project…" and Close (`index.ts:~858`).

| Button | Label (verbatim)                                           | Icon          | IPC                   | Main                                      |
| ------ | ---------------------------------------------------------- | ------------- | --------------------- | ----------------------------------------- |
| 1      | `Finder` on macOS, `Explorer` on Windows, `Files` on Linux | FolderOpen 14 | `muse:reveal-project` | `shell.openPath(project)`                 |
| 2      | `Terminal`                                                 | Terminal 14   | `muse:terminal`       | `openProjectTerminal(project, undefined)` |
| 3      | `Muse Code`                                                | none          | `muse:cli-terminal`   | `openProjectTerminal(project, [])`        |

- All three: `disabled={!project}`. Errors go to the error toast: `.catch((error: Error) => onError(error.message))`. There is no success message.
- `project` is the app's current project (`App.tsx:107`, `useState('')`), passed with `key={project}`.
- `Settings → Muse Code` and the docs page tell users to "use Muse Code in the project inspector to open the full CLI in Terminal" (`WorkspacePages.tsx:357`, `App.tsx:340` error text: "...Use /help, or open Muse Code in the project inspector for CLI commands.").

### 2.2 Main code (`src/main/index.ts`)

- `handle('reveal-project')` (`:697-700`): `error = await shell.openPath(await knownProject(project))`; `if (error) throw new Error(error)`. `openPath` on a folder opens it in Finder (it does not select the folder in its parent). Equivalent: `NSWorkspace.shared.open(URL(fileURLWithPath:isDirectory:true))`, as `BridgesPane.swift:206` already does.
- `handle('terminal')` (`:701-705`): `knownProject`, optional `login` boolean, then `openProjectTerminal(project, login ? ['login'] : undefined)`. No renderer code passes `login` (the preload/protocol have the parameter; `Inspector.tsx` does not), so `['login']` is dead from the UI.
- `handle('cli-terminal')` (`:706-709`): `openProjectTerminal(project, [])`.
- `knownProject` (`:263-280`): `realpath`, then the path (or its Muse worktree parent) must be in `preferences.recentProjects`, else throws **"Choose this project using Open project first."** A deleted folder throws the raw `realpath` ENOENT message. It does **not** show the trust dialog (`trustProject` is only for sessions).
- `openProjectTerminal(project, cliArgs?)` (`:314-372`), macOS branch (`:316-342`):
  - `cliBinary = muse.status.path || 'muse'` (the discovered CLI path, not the `cliPath` preference).
  - `quote(v) = "'" + v.replaceAll("'", "'\\''") + "'"`.
  - Command line = `cd <quote(project)>` + (cliArgs ? ` && <quote(cli)> <quote(arg)>...` : '').
    - **Terminal button:** `cd '/path/to/project'` only.
    - **Muse Code button:** `cd '/path/to/project' && '/Users/dom/.local/bin/muse'` (no arguments).
  - Run: `/usr/bin/osascript -e 'on run argv' -e 'tell application "Terminal"' -e 'activate' -e 'do script (item 1 of argv)' -e 'end tell' -e 'end run' <command line>`, timeout 10000 ms. The line is argv data, never put into script text.
  - No env passed (Terminal starts its own shell, so PATH comes from the user's Terminal profile). No working directory is set for osascript; the `cd` is inside the command.
  - Windows and Linux branches are not relevant (win32 `cmd.exe /c start`; Linux tries 8 terminal emulators and throws "Could not find a desktop terminal emulator.").
- The same function serves `mcp-login` (`:507`).

Errors that can reach the toast on macOS: the `knownProject` messages above; an osascript failure (`execFile` error text, such as the Automation-denied message from macOS; timeout after 10 s); and nothing from `openPath` beyond the system's error string.

### 2.3 Compare with `src/headless/terminal.ts` (what can be reused)

- `terminal.ts` is already a copy of the macOS branch: `quote`, `terminalCommand(folder, cli, cliArgs)` and `openInTerminal(command, run)` (the identical osascript argument list, timeout 10000). Header comment: "Terminal, as src/main/index.ts's openProjectTerminal opens it on macOS."
- **Gap:** `terminalCommand` **always** appends ` && <cli> <args>`. The Terminal button needs `cd '<project>'` alone (Electron's `cliArgs === undefined` case). Add a folder-only helper, or make the CLI optional. The "Muse Code" button is `terminalCommand(project, muse.status.path || 'muse', [])`, which gives the same line as Electron.
- `backend.ts` already has `knownProject(value)` (`:143-157`, same logic, using `current().recentProjects`) and an injectable `openTerminal` (`:83`, `:97`; tests pass a recorder). `mcp-login` (`:471-482`) is the working example: it calls `openTerminal(terminalCommand(homedir(), muse.status.path || 'muse', ['mcp', ...]))`.
- New backend methods needed: `method('terminal', ...)` and `method('cli-terminal', ...)`, both `knownProject` first. Both are in the parity test's `notYet` (`:47-48`). `reveal-project` is already `electronOnly` ("mMac reveals files with NSWorkspace"); no backend method needed. Parity test counts go up by two (headless 36 to 38).
- Swift side: `MuseBackend/Methods.swift` has `mcpLogin` (`:179`) but no `terminal` or `cliTerminal`. `SettingsModel.signIn` (`SettingsModel.swift:95`) shows the pattern (`do { try await client.mcpLogin(name) } catch { errorMessage = ... }`).

### 2.4 What mMac already has

- No Finder/Terminal/Muse Code buttons. `InspectorView.swift` ends with the usage panel (`:28-31`), with no footer.
- Existing NSWorkspace uses: `McpPane.swift:39` (`activateFileViewerSelecting`, which selects a file in its parent folder), `BridgesPane.swift:197-208` (`NSWorkspace.shared.open(folder)`, error "mMac could not open <folder>."), `MuseCodePane.swift:76`.
- Terminal opening has had **no live check yet**: spec line 137 says "The live check that Terminal opens moves to M4". The first osascript call to Terminal should raise the macOS "wants to control Terminal" Automation prompt. mMac's `Info.plist` has no `NSAppleEventsUsageDescription`, and the Electron app does not set one either. I could not confirm from the repo what macOS shows or whether the prompt names the app or `osascript`. Treat as an open question for the live run. A cold start of Terminal via `do script` may also open an extra empty window; I did not verify this and it is not mentioned in the repo.

### 2.5 Tests

- `tests/unit/headless-terminal.test.ts`: `terminalCommand` escaping (single quotes in folder, CLI and args; parsed and run by `/bin/sh` with literal args) and `openInTerminal` argument list. Covers the shared machinery only.
- `tests/unit/headless-backend.test.ts`: "signs in to remote servers only, through Terminal" (`mcp-login`).
- **Nothing** tests Electron's `reveal-project`, `terminal` or `cli-terminal`, `knownProject` for these channels, or the Inspector footer (`grep` finds no "Terminal"/"Finder" in `tests/e2e/*`).

---

### 3. App size baseline

### 3.1 Existing measurement method

None documented. `grep` across `docs/`, `scripts/`, `mac/scripts/` finds the spec's sentence only (`docs/superpowers/specs/2026-10-21-mac-app-design.md:7`: "344 MB on disk and about 229 MB of memory across four processes when idle"). It gives no command, date, machine, or definition of "idle".

### 3.2 Electron numbers: re-measured today (read-only)

- **On disk: reproduced exactly.** `du -sh "/Applications/Muse Desktop.app"` prints `344M` (installed 2026-10-13). Breakdown: `Contents/Frameworks` 289M (Electron Framework 285M, Sparkle 2.5M, Squirrel 380K, ReactiveObjC 372K, four helper apps about 232K each), `Contents/Resources` 55M, `Contents/MacOS` 52K. `du -sh` uses powers of 1024; Finder "Get Info" (powers of 1000) will show a different figure.
- **Also in /Applications:** `Muse.app`, 130M, owned by `admin`, installed 2026-10-18. I did not open it. It is not Muse Desktop, and no doc names it; do not use it for the baseline.
- **Memory: cannot be reproduced without launching.** No Muse Desktop or mMac process is running now (`ps` shows none). The four processes are most likely the Electron main process plus the GPU, network-service and renderer helpers (the `Frameworks` folder has helpers named Helper, Helper (GPU), Helper (Renderer), Helper (Plugin)). The repo does not say which; the Muse CLI child (`muse serve`) is a further process and is probably not in the 229 MB.
- **Re-measure method (Dom runs it, app idle for a fixed time such as 60 s with the same state each time):**
  - Activity Monitor: Memory column per process, summed.
  - Or: `footprint "Muse Desktop"` (physical footprint per process, nearest to Activity Monitor), and `ps -axo pid,rss,comm | grep "Muse Desktop"`, summing `rss` (KB / 1024). RSS double-counts pages shared between processes, so it reads higher than footprint. The repo does not record which one made 229 MB, so measure both for both apps and write the method next to the number.

### 3.3 mMac numbers (read-only `du` and `ls`)

| Item                 | Path                                                                                   | Size / note                                                                                                                                                                                     |
| -------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Release app (newest) | `.cache/mmac-rel/Build/Products/Release/mMac.app`                                      | **14M** (`mMac` binary 14,430,784 bytes, built 2026-10-22 12:31)                                                                                                                                |
| Release app (older)  | `.cache/mmac/Build/Products/Release/mMac.app`                                          | 11M (binary 11,450,752 bytes, built 2026-10-21 23:27, stale)                                                                                                                                    |
| Debug app            | `.cache/mmac/Build/Products/Debug/mMac.app`                                            | 11M (41 KB stub, `mMac.debug.dylib` 11.3 MB, `__preview.dylib` 17 KB; built 2026-10-22 15:03). Not a size baseline: the code is in the debug dylib                                              |
| Node binary          | `/usr/local/bin/node`, v24.12.0                                                        | 237,619,616 bytes (about 227 MiB), **not shipped**; the system copy                                                                                                                             |
| Backend checkout     | `node_modules` 661M (electron alone 311 MB, dev tools), `src` 11M, `mac/Packages` 484K | mMac runs `node --import tsx src/headless/server.ts` in the checkout named by `MMacRepository` (`project.yml`, `Launcher.swift`, `Transport.swift:27`), so the checkout is a runtime dependency |

Honest comparison: the **app bundle is 14M against 344M**, but mMac also needs the system Node (227 MiB), plus the checkout's `src` and the production part of `node_modules` (tsx, `@muse-code/sdk`, zod, MCP libraries; the 661M figure is mostly build tooling and cannot be counted). Neither Node nor the checkout is bundled, which the spec says on purpose (spec line 23). Report the bundle size and the dependencies separately, or the 344M comparison will mislead in both directions.

mMac `Launcher.swift:114-117` finds `node` by walking PATH (login-shell PATH, then `own["PATH"]`, then `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`).

### 3.4 mMac re-measure commands (for Dom, after M4 build)

- Disk: `du -sh .cache/mmac-rel/Build/Products/Release/mMac.app` (rebuild the Release scheme first, since the file there is from 2026-10-22 12:31). Use `du -sk` for an exact number.
- Memory, idle for the same time and state as the Electron run:
  - mMac: `footprint mMac` and `ps -o pid,rss,comm -p $(pgrep -x mMac)`.
  - Backend: `pgrep -f 'src/headless/server.ts'` gives the node PID; run `footprint -p <pid>` and `ps -o rss= -p <pid>`.
  - Count the Muse CLI child (`muse serve`) the same way for both apps, or leave it out of both.
- Stop condition for "idle": same project, no open conversation, no running turn, no Settings window.

---

### Surprises and ambiguities (short list)

1. Voice transcription is **not** done by Desktop. It shells out to `muse voice transcribe <wav>`; the CLI owns credentials and the service. No key in Desktop.
2. Every transcription re-runs CLI discovery (login shell `-ilc` up to 6 s, plus `muse --version`).
3. mMac has no `NSMicrophoneUsageDescription`; the first microphone use would end the process.
4. `terminalCommand` in `src/headless/terminal.ts` cannot produce the Terminal button's `cd`-only line.
5. The recorder stops at about 119 s, not 120 s; the file limit is 120 s.
6. Raw "Command failed: ..." text can reach the voice toast when stderr is empty.
7. Automation consent for Terminal has not been live-checked in mMac, and the first osascript call may prompt.
8. The 229 MB memory figure has no recorded method; the 344 MB disk figure reproduces exactly with `du -sh`.
