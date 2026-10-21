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
    stripInjectedTags(value)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Removes `<tag …>…</tag>` blocks that tools inject, as Electron's `stripInjectedTags`.
  static func stripInjectedTags(_ value: String?) -> String {
    guard var text = value, !text.isEmpty else { return "" }
    let block = try! NSRegularExpression(pattern: #"<([a-zA-Z_][\w.-]*)\b[^>]*>[\s\S]*?</\1>"#)
    for _ in 0..<4 {
      let next = block.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
      if next == text { break }
      text = next
    }
    if let closing = text.range(of: "</", options: .backwards),
      let end = text[closing.lowerBound...].firstIndex(of: ">"),
      text[closing.lowerBound...end].range(of: #"^</[a-zA-Z_][\w.-]*>$"#, options: .regularExpression) != nil
    {
      text = String(text[text.index(after: end)...])
    }
    if let opening = text.range(of: #"^<[a-zA-Z_][\w.-]*\b[^>]*>[\s\S]*"#, options: [.regularExpression, .caseInsensitive]) {
      text.removeSubrange(opening)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Project folders. Muse-created worktrees (`<project>/.muse/worktrees/<name>`) belong to their project.
public enum ProjectPath {
  public static func worktreeParent(_ path: String?) -> String? {
    guard let path,
      let match = path.firstMatch(of: #/^(.*)[/\\]\.muse[/\\]worktrees[/\\]([^/\\]+)[/\\]?$/#),
      !match.1.isEmpty
    else { return nil }
    return String(match.1)
  }

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

/// The conversation list, as Electron's `App.tsx` builds it (pinning and archiving arrive in M4).
public enum SidebarSections {
  public static func build(
    _ sessions: [Session], project: String, now: Date, calendar: Calendar = .current
  ) -> [SidebarSection] {
    let root = project.isEmpty ? nil : ProjectPath.root(of: project)
    let shown = sessions
      .filter { $0.kind != "subagent" && $0.kind != "reminder" }
      .filter { session in
        guard let root else { return true }
        return session.workspaceRoot.map(ProjectPath.root(of:)) == root
      }
      .sorted { activity($0) > activity($1) }
    var sections: [SidebarSection] = []
    for session in shown {
      let title = group(session, now: now, calendar: calendar)
      if sections.last?.title == title {
        sections[sections.count - 1] = SidebarSection(title: title, sessions: sections[sections.count - 1].sessions + [session])
      } else {
        sections.append(SidebarSection(title: title, sessions: [session]))
      }
    }
    return sections
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
  public static func text(_ value: String, now: Date = .now, locale: Locale = .current) -> String {
    guard let date = date(value) else { return "" }
    let minutes = now.timeIntervalSince(date) / 60
    if minutes < 1 { return "Now" }
    if minutes < 60 { return "\(Int(minutes))m" }
    if minutes < 1440 { return "\(Int(minutes / 60))h" }
    return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
  }

  /// Parses a CLI timestamp: ISO 8601, with or without fractional seconds.
  public static func date(_ value: String) -> Date? {
    let precise = ISO8601DateFormatter()
    precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}
