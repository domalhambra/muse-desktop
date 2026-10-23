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

Icon buttons have accessibility labels and help tags. Alerts, sheets and panels are native. The command menu, the slash and mention popups and the sidebar work from the keyboard. The composer handles Shift–Return and input methods. Text size and Reduce motion work with macOS's own settings. Statuses include text, not color alone. Images in replies never load, so remote content cannot appear in the transcript.
