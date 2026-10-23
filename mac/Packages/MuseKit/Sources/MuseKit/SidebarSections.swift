import Foundation
import MuseBackend

/// Conversation titles, as Electron's `sessionTitle` in `Primitives.tsx`.
public enum SessionTitle {
  public static func text(name: String?, title: String?, firstUserPrompt: String?) -> String {
    let raw = [name, title, firstUserPrompt].lazy.map(clean).first { !$0.isEmpty } ?? ""
    guard !raw.isEmpty else { return "Untitled conversation" }
    guard raw.count > 76 else { return raw }
    return String(raw.prefix(76)).trimmingCharacters(in: .whitespaces) + "…"
  }

  public static func of(_ session: Session) -> String {
    text(name: session.name, title: session.title, firstUserPrompt: session.firstUserPrompt)
  }

  /// Removes injected tags and collapses whitespace.
  static func clean(_ value: String?) -> String {
    let text = stripInjectedTags(value)
    return whitespace.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // Built once. NSRegularExpression is immutable and documented as thread-safe.
  static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
  static let tagBlock = try! NSRegularExpression(pattern: #"<([a-zA-Z_][\w.-]*)\b[^>]*>[\s\S]*?</\1>"#)
  static let closingTag = try! NSRegularExpression(pattern: #"^</[a-zA-Z_][\w.-]*>$"#)
  static let openingTag = try! NSRegularExpression(
    pattern: #"^<[a-zA-Z_][\w.-]*\b[^>]*>[\s\S]*"#, options: .caseInsensitive)

  /// Removes `<tag …>…</tag>` blocks that tools inject, as Electron's `stripInjectedTags`.
  static func stripInjectedTags(_ value: String?) -> String {
    guard var text = value, !text.isEmpty else { return "" }
    for _ in 0..<4 {
      let next = tagBlock.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
      if next == text { break }
      text = next
    }
    if let closing = text.range(of: "</", options: .backwards),
      let end = text[closing.lowerBound...].firstIndex(of: ">"),
      matches(closingTag, String(text[closing.lowerBound...end]))
    {
      text = String(text[text.index(after: end)...])
    }
    if matches(openingTag, text) { text = "" }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
    expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }
}

/// Project folders. Muse-created worktrees (`<project>/.muse/worktrees/<name>`) belong to their project.
public enum ProjectPath {
  public static func worktreeParent(_ path: String?) -> String? {
    guard let path,
      let match = worktree.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
      let parent = Range(match.range(at: 1), in: path), !parent.isEmpty
    else { return nil }
    return String(path[parent])
  }

  /// Electron's `worktreePattern` in `src/shared/worktree.ts`, built once.
  static let worktree = try! NSRegularExpression(
    pattern: #"^(.*)[/\\]\.muse[/\\]worktrees[/\\]([^/\\]+)[/\\]?$"#)

  public static func root(of path: String) -> String { worktreeParent(path) ?? path }

  /// The last non-empty part on either separator, or the path itself, as Electron's `projectName`.
  public static func name(of path: String) -> String {
    path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
  }

  public static func isWorktree(_ session: Session) -> Bool {
    session.worktree != nil || worktreeParent(session.workspaceRoot) != nil
  }
}

public struct SidebarSection: Identifiable, Equatable, Sendable {
  public let title: String
  public let sessions: [Session]
  public var id: String { title }
}

/// The conversation list, as Electron's `App.tsx` builds it (`visibleSessions`, `groupedSessions`).
public enum SidebarSections {
  /// The group pinned conversations form, in the normal view and in the archived view.
  public static let pinnedTitle = "Pinned"

  /// Session kinds that never show in the sidebar or in ⌘K.
  public static let hiddenKinds: Set<String> = ["subagent", "reminder", "sideChat"]

  /// Keeps a conversation when it matches the project filter, is not a subagent or reminder, and
  /// is archived exactly when `showArchived` is on. Pinned conversations come first, then the rest
  /// by last activity, newest first.
  public static func build(
    _ sessions: [Session], project: String, pinned: [String] = [], archived: [String] = [],
    showArchived: Bool = false, now: Date, calendar: Calendar = .current
  ) -> [SidebarSection] {
    let root = project.isEmpty ? nil : ProjectPath.root(of: project)
    let pinned = Set(pinned)
    let archived = Set(archived)
    let shown = sessions
      .filter { !hiddenKinds.contains($0.kind ?? "") }
      .filter { archived.contains($0.sessionId) == showArchived }
      .filter { session in
        guard let root else { return true }
        return session.workspaceRoot.map(ProjectPath.root(of:)) == root
      }
      .sorted { first, second in
        let (firstPinned, secondPinned) = (pinned.contains(first.sessionId), pinned.contains(second.sessionId))
        if firstPinned != secondPinned { return firstPinned }
        let (a, b) = (activity(first), activity(second))
        return a != b ? a > b : first.sessionId < second.sessionId
      }
    var sections: [SidebarSection] = []
    for session in shown {
      // Pinned wins over the date, in the archived view too.
      let title = pinned.contains(session.sessionId) ? pinnedTitle : group(session, now: now, calendar: calendar)
      if sections.last?.title == title {
        sections[sections.count - 1] = SidebarSection(title: title, sessions: sections[sections.count - 1].sessions + [session])
      } else {
        sections.append(SidebarSection(title: title, sessions: [session]))
      }
    }
    return sections
  }

  /// The row after or before `sessionId` in the visible order, across sections, as ⌘⇧] and ⌘⇧[
  /// move. Nil at either end, or with no rows. The first row when `sessionId` is nil or not shown.
  public static func neighbor(of sessionId: String?, in sections: [SidebarSection], forward: Bool) -> String? {
    let ids = sections.flatMap { $0.sessions.map(\.sessionId) }
    guard !ids.isEmpty else { return nil }
    guard let sessionId, let index = ids.firstIndex(of: sessionId) else { return ids.first }
    let next = forward ? index + 1 : index - 1
    return ids.indices.contains(next) ? ids[next] : nil
  }

  /// `lastActivityAt || updatedAt`: the time a row sorts, groups and shows by.
  public static func activity(_ session: Session) -> String {
    ToolPresentation.first(session.lastActivityAt) ?? session.updatedAt
  }

  static func group(_ session: Session, now: Date, calendar: Calendar) -> String {
    guard let date = RelativeTime.date(activity(session)) else { return "Earlier" }
    let today = calendar.startOfDay(for: now)
    if date >= today { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return "Yesterday" }
    if let week = calendar.date(byAdding: .day, value: -7, to: today), date >= week { return "Previous 7 days" }
    return "Earlier"
  }
}

/// Electron's `friendlyTime`: Now, minutes, hours, then a short date.
public enum RelativeTime {
  /// `calendar` and its time zone decide the short date's day, as `SidebarSections` groups by it.
  public static func text(
    _ value: String, now: Date = .now, locale: Locale = .current, calendar: Calendar = .current
  ) -> String {
    guard let date = date(value) else { return "" }
    let minutes = now.timeIntervalSince(date) / 60
    if minutes < 1 { return "Now" }
    if minutes < 60 { return "\(Int(minutes))m" }
    if minutes < 1440 { return "\(Int(minutes / 60))h" }
    var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
    style.locale = locale
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    return date.formatted(style)
  }

  /// Parses a CLI timestamp: ISO 8601, with or without fractional seconds.
  public static func date(_ value: String) -> Date? {
    (try? precise.parse(value)) ?? (try? plain.parse(value))
  }

  // Built once; a format style is a Sendable value, cheap to parse with.
  static let precise = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  static let plain = Date.ISO8601FormatStyle()
}
