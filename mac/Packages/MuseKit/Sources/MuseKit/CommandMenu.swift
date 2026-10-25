import Foundation
import MuseBackend

/// What choosing a ⌘K entry does. The app closes the sheet first, then runs it, as Electron's
/// `invoke` does.
public enum CommandMenuAction: Equatable, Sendable {
  case newConversation
  case openProject
  case openSettings
  /// Opens the conversation with this id.
  case open(String)
  /// Saves this theme preference.
  case theme(String)
}

/// The three groups, in Electron's order. The sheet draws the titles in capitals, as Electron's CSS.
public enum CommandMenuGroup: String, CaseIterable, Sendable {
  case actions = "Actions"
  case conversations = "Recent conversations"
  case themes = "Themes"
}

public struct CommandMenuEntry: Identifiable, Equatable, Sendable {
  public let id: String
  public let group: CommandMenuGroup
  public let title: String
  public let subtitle: String
  /// The key hint, with a space as in Electron: `⌘ N`. Nil shows the arrow icon.
  public let shortcut: String?
  public let action: CommandMenuAction
}

/// The ⌘K list, as Electron's `CommandMenu.tsx` builds it, with the spec's fixes: conversations
/// leave out subagent, reminder and archived sessions, sort by last activity, and stop at 25, so
/// Actions and Themes always show. Electron cut the whole list at 30. Themes lists the two themes
/// mMac keeps.
public enum CommandMenu {
  public static let conversationLimit = 25
  public static let placeholder = "Search commands and conversations…"
  /// The field's accessibility label.
  public static let fieldLabel = "Search commands and conversations"
  public static let emptyState = "No matches. Try a project or conversation name."

  /// The entries for `query`: a case-insensitive substring match on the title, one space, and the
  /// subtitle. The query is not trimmed. Not `localizedStandardContains`, which ignores diacritics.
  /// Swift compares whole characters, so a decomposed accent (e + U+0301) matches differently from
  /// Electron's JS `includes`; Mac text is almost always precomposed.
  public static func entries(sessions: [Session], archived: [String], query: String) -> [CommandMenuEntry] {
    let needle = query.lowercased()
    func matches(_ entry: CommandMenuEntry) -> Bool {
      // JavaScript's `includes('')` is true; Foundation's `contains("")` is not.
      needle.isEmpty || "\(entry.title) \(entry.subtitle)".lowercased().contains(needle)
    }
    let hidden = Set(archived)
    let actions = [
      CommandMenuEntry(
        id: "new", group: .actions, title: "New conversation", subtitle: "Start a conversation",
        shortcut: "⌘ N", action: .newConversation),
      CommandMenuEntry(
        id: "open", group: .actions, title: "Open project", subtitle: "Choose a folder on your Mac",
        shortcut: "⌘ O", action: .openProject),
      CommandMenuEntry(
        id: "settings", group: .actions, title: "Open settings", subtitle: "Appearance and Muse Code connection",
        shortcut: "⌘ ,", action: .openSettings),
    ]
    let conversations = sessions
      .filter { !SidebarSections.hiddenKinds.contains($0.kind ?? "") && !hidden.contains($0.sessionId) }
      .sorted { first, second in
        // Ties break on the id, as the sidebar does, so the order is stable.
        let (a, b) = (SidebarSections.activity(first), SidebarSections.activity(second))
        return a != b ? a > b : first.sessionId < second.sessionId
      }
      .map { session in
        CommandMenuEntry(
          id: "conversation:\(session.sessionId)", group: .conversations, title: SessionTitle.of(session),
          subtitle: session.workspaceRoot.flatMap { $0.isEmpty ? nil : ProjectPath.name(of: $0) } ?? "Conversation",
          shortcut: nil, action: .open(session.sessionId))
      }
      .filter(matches)
      .prefix(conversationLimit)
    let themes = ThemeName.allCases.map { theme in
      CommandMenuEntry(
        id: theme.rawValue, group: .themes, title: "Switch to \(theme.label)", subtitle: theme.hint,
        shortcut: nil, action: .theme(theme.rawValue))
    }
    return actions.filter(matches) + conversations + themes.filter(matches)
  }

  /// The highlight after Up or Down: it stops at both ends and does not wrap, as in Electron.
  public static func moved(_ index: Int, by step: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index + step, 0), count - 1)
  }
}
