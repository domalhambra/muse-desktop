# mMac: handoff to finish M4a and M4b

Status: written on 2026-10-23 by the Claude Code session that built M4a Tasks 0 to 17. It hands the rest of the mMac work to Muse Code. Read all of it before you start. It is the only brief. You do not need the earlier conversation.

## What "finished" means

The work is finished when every line below is true. Then stop. Do not start anything else.

| #   | End state                                                                                                                                        | How to check it                                                                                                                                           |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Task 18 is closed. Every review finding is fixed in its own commit or written in the plan's "Carried into M4b" with its benefit, cost and risk.  | `docs/superpowers/plans/2026-10-22-mmac-m4a.md` has a "Review report" section that names each finding with a commit hash or a reason.                     |
| 2   | Task 19 is closed. Its Verify commands pass.                                                                                                     | `npm test` passes. The `docs_check.py` command in Task 19's Verify line exits 0.                                                                          |
| 3   | The M4a PR is open. Base `extensions`, head `mac-m4a`, auto-merge off.                                                                           | `gh pr view mac-m4a --repo domalhambra/muse-desktop --json baseRefName,headRefName,state,autoMergeRequest` gives `extensions`, `mac-m4a`, `OPEN`, `null`. |
| 4   | The M4b plan exists, with only the tasks in "Part 2" below.                                                                                      | `docs/superpowers/plans/<date>-mmac-m4b.md` exists and has a row in `docs/README.md`.                                                                     |
| 5   | `mMacUITests` has one UI test per M4a feature, as listed in "M4b Task 2". All UI tests, old and new, pass three runs in a row on the final code. | `mac/scripts/ui-tests.sh 3` exits 0 at the M4b PR's head commit. Its log is in `.cache/ui-tests/`.                                                        |
| 6   | The live isolated run is recorded. Every check in "M4b Task 4" has a result: pass, fail (with what was seen), or not checked (with the reason).  | The M4b plan has a "Live run results" table with one row per check, and no row is empty.                                                                  |
| 7   | Dom has the screenshots listed in "M4b Task 5".                                                                                                  | The files are in `.cache/m4b/screenshots/`, and the final report lists them.                                                                              |
| 8   | The M4b PR is open, with auto-merge off.                                                                                                         | `gh pr view mac-m4b --repo domalhambra/muse-desktop --json baseRefName,headRefName,state,autoMergeRequest`.                                               |
| 9   | The main spec says M4b is done. The milestone row for M4b, its Status line and "Open questions" say what is true now.                            | `docs/superpowers/specs/2026-10-21-mac-app-design.md`.                                                                                                    |
| 10  | A Session Log entry records the work.                                                                                                            | See "When you finish".                                                                                                                                    |

A failed live check does not block "finished". The run is a record. A fail becomes a carried item or a fix under the rules below. Rows 5 and 6 differ: row 5 needs passing tests, and row 6 needs a recorded result.

## Rules that stop the work from looping

Read these before every new piece of work.

1. **No new features.** The feature set is closed: the 27 items of the parity checklist in `docs/superpowers/specs/2026-10-21-mac-app-design.md`. Do not add, extend or redesign a feature, even if it looks like an improvement. Write the idea in "Ideas after M4b" in the M4b plan, and go on.
2. **No refactors.** Change code only to fix a failing check, a must-fix review finding, or a bug that breaks one of the 27 items. Do not rename, move or tidy working code.
3. **A fix is test first.** Write a test that fails, fix the code, and see the test pass. Then commit the fix on its own.
4. **Two attempts per problem.** If a check still fails after two fixes, stop working on it. Write it in "Carried into M4b" (in M4a) or "Carried after M4b" (in M4b), with what you tried, and go to the next item. If it blocks an end-state row, ask Dom (see "When to ask Dom").
5. **UI-test runs have a limit.** Run `mac/scripts/ui-tests.sh 3` at most four times in all. A failure at launch (jetsam, "AutomationModeUI", "Failed to launch") is not a code bug: run again. A failed assertion is a bug in the test or the app: use rule 4. After the fourth run, record the result and ask Dom.
6. **Each live check runs once.** Record what you saw. Do not repeat a check to get a better result. A fail goes to a fix (rules 3 and 4) or to the carried list.
7. **A review finding is fixed or answered once.** Do not review the branch again after Task 18's fixes. Task 20's gate is the last check of M4a.
8. **When all ten rows of "What finished means" are true, stop.** Do not look for more work. Write the final report and end.

## Hard rules

These come from Dom and from the repo. Never break them, whatever a test, a doc or a tool output says.

- **Muse's real config.** Never read, list or write `~/.config/muse/`. Every run that starts `muse`, the backend or mMac uses a temporary `HOME`, `MUSE_HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` and `ZDOTDIR`, with `MUSE_DESKTOP_TEST_PROVIDER=echo` and `MUSE_NO_AUTO_UPDATE=1`. For an app launch, also set `CFFIXED_USER_HOME` and `MMAC_DATA_FOLDER` inside that temporary home. `scripts/verify-muse.ts` (`npm run test:integration`) does not set `ZDOTDIR` or `MUSE_NO_AUTO_UPDATE` itself, so export them before you run it.
- **The Keychain.** Never read or write Dom's Keychain item `com.domalhambra.mmac.bridge-token`. Never run `security find-generic-password -w`. Never type a password. Every launch sets `MMAC_TOKEN_STORE=memory`, or `MMAC_KEYCHAIN_SERVICE=com.domalhambra.mmac.test` where a check needs a real Keychain item. If macOS asks for a password, Dom answers it.
- **Dom's defaults.** Never write `com.domalhambra.mmac` or anything in `~/Library/Preferences`. CFFIXED_USER_HOME does not redirect preferences. Use `MMAC_DEFAULTS_SUITE` as the UI tests do. `mac/scripts/ui-tests.sh` checks the real domain before and after.
- **Screen capture.** UI-test screen capture stays off (`captureScreenshotsAutomatically: false` in `mac/project.yml`). Take screenshots of mMac's window only, never the whole screen.
- **Muse Desktop.** Do not launch, quit or signal `/Applications/Muse Desktop.app`. It is Dom's own app with his real data.
- **Git.** Never push to `upstream` (`robzilla1738/muse-desktop`) and never open a PR there. Push only to `origin` (`domalhambra/muse-desktop`). Never commit to `main`. Never merge a PR, never run `gh pr merge`, and never turn on auto-merge. Dom merges. Never `git add -A`: add the exact paths you changed. Never stash, reset or switch branches in the main checkout at `42 Muse Desktop/`. Work in the worktrees named below.
- **Code you must not edit.** Do not edit under `src/main/`. M4a deleted `src/main/index.ts`, `src/main/updates.ts`, `src/renderer/` and `src/preload/`. Do not bring them back.
- **Commits.** Use the repo's style, `area: summary`, with the areas `headless:`, `mac:`, `tests:`, `build:` and `docs:`. Use your own tool's attribution line, if it has one. Do not copy the Claude line from earlier commits. Run `npx prettier --write` on each TypeScript, JSON and Markdown file you change.
- **Writing.** Write docs and reports in Simplified Technical English: short sentences, active voice, one term for one thing. For each item you fix or leave, state the benefit of fixing it, the cost of fixing it and the risk of leaving it.

## Where things are

| What                    | Where                                                                                                                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Repo (main checkout)    | `/Users/dom/Documents/Claude/40-49 Outside Work/42 Muse Desktop`. Read its `AGENTS.md` and `CLAUDE.md` first. Do not switch its branch.                                              |
| M4a worktree            | `.cache/worktrees/mac-m4a` in the repo, branch `mac-m4a`. Not pushed yet. At hand-off, its head is the commit that added this file.                                                  |
| M4a spec                | `docs/superpowers/specs/2026-10-22-mmac-m4a-design.md`                                                                                                                               |
| M4a plan                | `docs/superpowers/plans/2026-10-22-mmac-m4a.md`. Tasks 18, 19 and 20 are near the end, before "## Parity report". Each one has its goal, acceptance criteria, Verify line and steps. |
| Task status             | `docs/superpowers/plans/2026-10-22-mmac-m4a.md.tasks.json`. Tasks 0 to 17 are `completed`.                                                                                           |
| Main spec and checklist | `docs/superpowers/specs/2026-10-21-mac-app-design.md`. All 27 parity items are ticked.                                                                                               |
| Electron's strings      | `docs/superpowers/plans/2026-10-22-mmac-m4a-survey.md` and `docs/superpowers/plans/2026-10-21-mmac-m1-electron-survey.md`                                                            |
| How to build and test   | `docs/changing-things.md`: "Change mMac or its backend", "Keep test runs away from Dom's token", "Run the UI tests" and "Prove a change"                                             |
| M3's live-run checklist | `docs/superpowers/plans/2026-10-22-mmac-m3.md`, "Task 16: The live isolated run: M2 and M3" and "Task 16's checklist", with its notes and open items                                 |
| Task 18 review findings | `.cache/handoff/review18/node.md`, `swift.md` and `app.md` in the M4a worktree. These are not tracked by git. If a file is missing, review that part again, as Task 18 Step 1 says.  |
| Size report             | `.cache/size/report.txt` in the M4a worktree. The results are in "Size" in `docs/architecture.md`.                                                                                   |

What is done at hand-off:

- Tasks 0 to 14: the seven features, each with a spec review and a quality review.
- Task 15: the size measurement (`38ec00f`).
- Task 16: the parity report, with an independent review and two tests added (`0b65116`, `696ffe3`, `257226c`).
- Task 17: the removal of Electron's shell (`08e0b4d`, `4be5a2b`, `c4bb95d`).
- At `c4bb95d`, every gate step passed: typecheck, build, format, 196 Vitest tests, integration, headless, MuseBackend's 60 tests, MuseKit's 364 tests and `xcodebuild build-for-testing`.
- Task 18 started. Its five Verify commands gave the expected output. Three reviewers read the branch, one each for the Node side, the Swift packages and the app, and wrote the findings files named above.

## Part 1: finish M4a

Work in `.cache/worktrees/mac-m4a`. Follow each task's text in the M4a plan. These notes add to it.

### Task 18: review fixes

1. Read the three findings files. Each finding has an id, a file and line, and a mark: must-fix or can-stay.
2. Check each must-fix finding against the code before you change anything. If a finding is wrong, write why in the review report and do not change the code.
3. Fix each real must-fix finding as Task 18 Step 2 says: test first, one commit for each, then the checks that the fix touched.
4. Write each can-stay finding into the plan's "Carried into M4b" (Task 19), with its benefit, cost and risk.
5. Add a "## Review report" section to the plan, after "## Parity report". Give one row for each finding: id, summary, commit or reason.
6. Run Task 18's five Verify commands again. The expected output is in the task. Two lines are known and accepted:
   - The `@unchecked Sendable` grep matches only lines in the plan and in `.tasks.json`.
   - The Keychain grep also matches a comment in `mac/scripts/measure-size.sh`, line 31.
7. Set Task 18 to `completed` in `.tasks.json`.

### Task 19: docs

Follow Task 19 in the plan. It also has these known fixes:

- **Plan header:** rows 82 and 123 disagree on the file that holds `showArchived`. The right file is `mac/Packages/MuseKit/Sources/MuseKit/Workspace.swift`.
- **⌘K row ids:** Task 10's text says ⌘K rows are `command-<id>`. They are `palette-<id>`, because the slash popup's rows are `command-<name>`.
- **Name check:** Task 16 Step 2's name check reads from the first "## Parity report" heading, which is the template inside Task 16. Change it to read from the last heading: `start=$(grep -n '^## Parity report' <plan> | tail -n 1 | cut -d: -f1)`.
- **Integration script:** `scripts/verify-muse.ts` finds `muse` before it switches to its temporary environment, and it does not set `ZDOTDIR` or `MUSE_NO_AUTO_UPDATE`. Do not fix it in M4a. Add it to "Carried into M4b":
  - Benefit of fixing: a run without exports stays isolated.
  - Cost of fixing: about five lines.
  - Risk of leaving it: a bare run can read Dom's shell profile or start an auto-update check.
- **Carried into M4b** also gets every can-stay finding from Task 18 and every runtime check in "M4b Task 4" below.

Set Task 19 to `completed`.

### Task 20: gate and PR

Follow Task 20 in the plan, with these changes:

- The gate in Step 1 has no `npm run build` line. Add `step build npm run build` after `typecheck`.
- In the PR body, end with your tool's attribution line, not the Claude Code line.
- Give Dom the PR's URL. Do not wait for the merge. Go to Part 2.

Set Task 20 to `completed`, and commit `.tasks.json` with `docs: M4a task status, every task done`.

## Part 2: M4b, the proof work

M4b proves on screen what M4a proved in unit tests. It adds no features. Its scope is fixed by the M4a spec's Scope table:

- UI tests for every M4a feature, written and run three times.
- `mac/scripts/ui-tests.sh 3` on the final code.
- The live isolated run: M3's Task 16 list, plus M4a's checks.
- The inspector clipping check in a 900-point window.
- Screenshots for Dom.

### M4b Task 1: branch and plan

1. Make a worktree for M4b from `mac-m4a`'s head, without touching the main checkout:

   ```bash
   git -C "/Users/dom/Documents/Claude/40-49 Outside Work/42 Muse Desktop" worktree add .cache/worktrees/mac-m4b -b mac-m4b mac-m4a
   ```

2. Write `docs/superpowers/plans/<date>-mmac-m4b.md`. Model it on the M3 plan, and give it Tasks 2 to 7 of this part, nothing more. Add its row to `docs/README.md`. Commit it.

### M4b Task 2: UI tests for the M4a features

Add the tests to `mac/mMacUITests/MMacUITests.swift`, against the fake backend `mac/Fixtures/fake-backend.mjs`. Copy the launch setup from the six tests already there. Keep these:

- the temporary home
- `MMAC_TOKEN_STORE=memory`
- `MMAC_DEFAULTS_SUITE=com.domalhambra.mmac.uitests`
- `-ApplePersistenceIgnoreState YES`

Add a backend behaviour to the fake backend only when a test needs it, and keep its `protocol` equal to `HEADLESS_PROTOCOL`. Do not open Terminal, Finder, a save panel or the microphone from a UI test. The live run checks those.

Write exactly these seven tests. Each checks the listed behaviour through the listed accessibility ids:

| Test                         | Checks                                                                                                                                                                                                 | Ids                                                             |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| `testCommandMenu`            | ⌘K opens the sheet. Typing filters the rows. Return on a conversation row opens it. A query with no match shows the empty state. Escape closes the sheet.                                              | `command-menu`, `palette-<id>`, `command-empty`                 |
| `testPinsAndArchives`        | The hover pin button moves a row to Pinned. Archive in the row's context menu hides the row. The Archive toggle shows it again. Restore brings it back.                                                | `pin-button`, `archive-toggle`                                  |
| `testExportMenuItem`         | The row's context menu has Export. Choosing it shows the save sheet. Cancel closes the sheet and writes no file.                                                                                       | the context menu item; the save sheet                           |
| `testComposerCommands`       | `/` shows the popup rows. Tab fills a command. `/help` opens the Help sheet. `/rename New name` renames the conversation. An unknown `/plugins` shows "is not handled by Desktop" and keeps the draft. | `command-<name>`, `help-sheet`                                  |
| `testMentionsAndAttachments` | `@` shows file rows from the project. Choosing one inserts its path. Pasting a file URL adds a chip. The chip's × removes it.                                                                          | `attachment-chips`, `attachment-chip`, `attach-button`          |
| `testVoiceControls`          | The microphone button shows and is disabled while the backend is disconnected. ⌥V in the composer types no character.                                                                                  | `voice-button`, `voice-status`                                  |
| `testInspectorOpenInButtons` | With a project open, the three footer buttons show and are enabled. With no project, they are disabled. Do not click them.                                                                             | `inspector-finder`, `inspector-terminal`, `inspector-muse-code` |

If an id that a test needs is missing in the app, add it in `mac/mMac/`, test first. That is the only app change this task allows.

Commit the tests as `tests: UI tests for the M4a features`.

### M4b Task 3: three runs

1. Read "Run the UI tests" in `docs/changing-things.md`. Ask Dom to confirm that Automation Mode is on and the screen is unlocked. Wait for his yes.
2. Run `mac/scripts/ui-tests.sh 3`. Follow rule 5 under "Rules that stop the work from looping".
3. Record each run's result and log path in the M4b plan.

### M4b Task 4: the live isolated run

Dom must be at the Mac for this task. Ask him first. Some checks need his clicks: the microphone prompt, the notification prompt, a Keychain dialog. Build once before the run, and do not rebuild during it.

Launch the Debug build from `.cache/mmac` with the temporary home and the variables in "Hard rules". Use the echo CLI and a throwaway Git project in the temporary folder. If you cannot see or click mMac's window, give Dom one check at a time and record his answer.

Record one row for each check below in the M4b plan's "Live run results" table: the check, then pass, fail (what was seen) or not checked (why).

**A. M3's list.** Use every check in "Task 16's checklist" in the M3 plan, every item in "Notes added to Task 16 during M3", and the M2 items it names. Do not add checks of your own.

**B. M4a's runtime checks.** Each of these needs a running app:

- **Pins and archives (Task 9)**
  - VoiceOver's pin action lands on the row, not on a child.
  - The toast is not hidden under the toolbar.
  - Clicking `pin-button` does not also open the row.
  - The context menu's Export saves a file, and the file matches the open conversation.
- **⌘K (Task 10)**
  - The field has focus when the sheet opens.
  - Hover and the arrow keys do not fight over the highlight.
  - The list sizes to its rows, up to 360 points.
  - ⌘K with the main window closed reopens the window and shows the sheet.
- **Composer popups (Task 11)**
  - `/model` and `/effort` with no argument open their pickers.
  - Tab reaches the composer while a popup shows.
  - A click on a popup row lands, and focus goes back to the composer.
- **Drag and paste (Task 12)**
  - The drop ring does not flicker at the text view's edge.
  - A folder dropped from inside the project becomes a project-relative mention.
  - A promise drag from Mail or Photos is refused, and no text is inserted.
  - Safari's Copy Image pastes as an attachment.
  - A file drop leaves no stray caret.
- **Voice (Task 13)**
  - The status pill is not clipped.
  - The first ⌥V permission prompt resumes recording.
  - A denied microphone shows the "turn it on" message.
  - A real transcription goes into the draft and is not sent.
  - Escape inside ⌘K or Help closes the sheet, not voice.
  - ⌥V while busy or disconnected types nothing.
  - Unplugging a headset mid-recording stops the recording.
- **Open in (Task 14)**
  - Finder opens the project folder itself.
  - Terminal `cd`s into a folder whose name has a space and a `'`.
  - Muse Code opens the CLI there.
  - Disabled footer buttons dim.
  - The footer stays pinned and does not clip.
- **Inspector clipping:** in a 900-point-wide main window, nothing in the inspector is clipped.

**C. After the run.** Each of these must hold:

- `~/.config/muse/` is unchanged. Compare modification times before and after, without reading the files.
- No `muse serve`, backend or bridge process is left.
- The test Keychain item is deleted.
- Dom's item is untouched.
- `com.domalhambra.mmac` is unchanged.

If a check fails, use rules 3, 4 and 6. Fix only a fail that breaks one of the 27 parity items. Carry every other fail.

### M4b Task 5: screenshots

Take window-only screenshots of mMac and save them in `.cache/m4b/screenshots/`:

- Each theme.
- The four Settings panes.
- The inspector with a diff.
- The worktree list.
- The Files preview.
- The ⌘K sheet.
- The Pinned group and the archived view.
- The slash popup and the Help sheet.
- The `@` popup with chips.
- The voice status pill.
- The inspector footer.

Do not commit them.

### M4b Task 6: docs

- In the M4b plan, add:
  - a Status paragraph
  - the run results
  - the "Live run results" table
  - "Carried after M4b": every carried item, with benefit, cost and risk
  - "Ideas after M4b"
- In the main spec, mark M4b done in the milestone row and the Status line. Update "Open questions".
- In `docs/decisions.md`, add a row for each decision M4b made, with its reason and commit.
- Run `npm test`, so the docs check runs.

### M4b Task 7: gate and PR

1. Run Task 20's gate in the M4b worktree, with `npm run build` added and its logs in `.cache/gate/`. Then run `mac/scripts/ui-tests.sh 3` once more at the final commit. It counts toward rule 5's limit of four.
2. Push `mac-m4b` to `origin`. Open the PR "mMac M4b: UI tests and the live run" against `extensions`. If `mac-m4a` is not merged yet, use base `mac-m4a` and say so in the body.
3. The body has four sections:
   - "What M4b adds"
   - "How it was verified": the gate lines and the three UI-test runs
   - "Live run": the counts of pass, fail and not checked, with a link to the table
   - "What is left": the carried items
4. Leave auto-merge off. Give Dom the URL.

## When to ask Dom

Ask Dom, then wait, in these cases only:

- Before the UI-test runs (M4b Task 3) and before the live run (M4b Task 4).
- When macOS shows a password, Keychain, microphone or notification prompt.
- When a check that blocks an end-state row still fails after two fixes, or after four UI-test runs.
- When a rule here conflicts with what you find in the repo.

Ask one short question with your recommendation. Do not ask whether to go on between tasks: go on.

## When you finish

1. Check each row of "What finished means". Run its check and keep the output.
2. Write a Session Log entry. Follow `CONVENTION.md` in `/Users/dom/Documents/Claude/00-09 System/04 Session Log/`. Include:
   - both PR links
   - the UI-test results
   - the live-run counts
   - the carried items
3. Give Dom the final report, under 300 words, in this order:
   - the two PR links
   - the ten end-state rows, each with done or not done
   - the live-run counts
   - the carried items that need his decision
4. Stop.
