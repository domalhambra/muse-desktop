# Design system

mMac keeps the layout of upstream's Electron app in native SwiftUI: a sidebar, one conversation pane, and an optional inspector on the right. The window has the standard macOS title bar and toolbar. The composer stays visible while the transcript scrolls, and the transcript follows new messages only while the reader is near the bottom.

## Themes

Two themes, both dark:

- **Muse**, the default: electric blue with the Muse glow.
- **Moonlight**: navy and slate.

Their colors come from upstream's tokens.css, and live in `ThemePalette` in `mac/Packages/MuseKit/Sources/MuseKit/SettingsRules.swift`. `mac/mMac/Theme.swift` turns them into SwiftUI colors and applies the theme, the text size and Reduce motion at the root of each window. Change a color only there. Upstream's Daylight, Grove and Plush themes and its light mode are dropped (see the decisions in the main spec).

## Typography

Functional text uses the system font. Conversation text has three sizes (`TextSize`): Compact is 14 points, Comfortable is 15 points and the default, and Large is 17 points. Code uses the system monospaced font. Layouts adapt through wrapping and spacing instead of shrinking small labels.

## Copy conventions

Use sentence case and concise action labels. **Project** means a local folder; **conversation** means a Muse session. **Muse Code** names the installed CLI and its settings. **Settings** is used the same way in the sidebar, the menu bar, the command menu and the Settings window. Keyboard hints are `↵ Send` and `⇧ ↵ New line`. Status text reports facts, such as Connected to Muse Code. Electron's strings are the default: `docs/decisions.md` records each place mMac differs.

## Accessibility

Icon buttons have accessibility labels and help tags. Alerts, sheets and panels are native. The command menu, the slash and mention popups and the sidebar work from the keyboard. The composer handles Shift–Return and input methods. Text size and Reduce motion work with macOS's own settings. Statuses include text, not color alone. Images in replies never load, so remote content cannot appear in the transcript. A subagent sheet is read-only.

The composer's Mode picker names Muse's four modes as Muse words them: Allow all, Prompt unmatched, On request, Deny unmatched. A mode Muse names that the picker does not know shows as Muse's own name for it. The side chat and child sheets' fields are native: no custom rounded-rectangle drawing, as in Dom's design standards.

## Usage, schedules and change cards (M5b)

The usage footer is one line at the bottom of the sidebar, such as "5-hour 42% · Week 18%". At 80% it turns amber and at 100% red, on the icon only, because amber text on the sidebar fails contrast. VoiceOver reads "5-hour 42 percent, week 18 percent", so color never carries the meaning alone. A click opens a popover with both bars, the reset times, "as of" and the tier. With no usage observed, the line is hidden, never "0%". A turn that a limit stops shows "Session limit reached. Resets at 3:40 PM." (or Weekly, or Usage), then "Your conversation is saved. mMac can send again after the reset."

Settings has a fifth pane, Scheduled, with Desktop's words: Hourly, Daily, Weekdays, Weekly, Manual and Custom (cron). A next run 7 or more days away shows as a date; day names are English. The sidebar has a Scheduled group, one row per active task. A finished run's notice is "Scheduled task <name> finished".

A change card speaks to someone who does not follow Git. Help's Proposed changes text says it: the project has a master copy, a pull request is a proposed edit on a draft copy, and Accept merges the draft into the master copy. The card shows a headline, a delivery track, a risk light, dependencies, Accept and Ask why. Branches, commits and diffs stay under Show details. The track and the buttons wrap, so the card fits the inspector at its narrowest. A merged PR that is not Live says "Accepted into <branch>". Pictures in a PR's description load over `https` only.
