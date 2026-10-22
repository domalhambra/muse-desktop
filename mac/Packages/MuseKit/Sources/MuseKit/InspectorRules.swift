import Foundation
import MuseBackend

/// One row of a diff, as Electron's `parseDiffLines` in `Inspector.tsx`.
public struct DiffLine: Equatable, Sendable, Identifiable {
  public enum Kind: Equatable, Sendable { case meta, hunk, added, removed, context }

  /// The row's position. A diff is replaced whole, never edited, so position is identity.
  public let id: Int
  public let kind: Kind
  public let oldNumber: Int?
  public let newNumber: Int?
  public let text: String
  /// On a working-tree hunk header: the hunk's index, counted from 0, for `revertHunk`. Hunks in
  /// the "Staged changes" section have none, because `revertHunk` counts the working diff only.
  public let hunkIndex: Int?

  /// The one gutter Electron draws: the new line number, else the old one.
  public var gutter: String { (newNumber ?? oldNumber).map(String.init) ?? "" }

  /// Differs from Electron in four ways:
  /// - A final newline adds no empty row. For an untracked file, `getGitDiff` splits its content on
  ///   "\n", so a file that ends in a newline gives a last row of a bare `+`. That row is dropped too.
  /// - A `\ No newline at end of file` line is meta, not context.
  /// - An untracked file's lines (which `getGitDiff` writes with no hunk header) are numbered from 1.
  /// - Inside a hunk, a line that starts `---` or `+++` (a removed `-- note`, an added `++ x`) is
  ///   content and keeps its number. Electron reads it as a file header. A `diff ` line ends the hunk.
  public static func parse(_ diff: String) -> [DiffLine] {
    var lines = diff.components(separatedBy: "\n")
    // utf8, because Swift reads "\r\n" as one Character that is not "\n".
    if diff.utf8.last == 10 { lines.removeLast() }
    var rows: [DiffLine] = []
    var oldLine = 0
    var newLine = 0
    var working = false
    var workingHunks = 0
    var newFile = false
    var inHunk = false
    func add(_ kind: Kind, _ text: String, old: Int? = nil, new: Int? = nil, hunk: Int? = nil) {
      rows.append(DiffLine(id: rows.count, kind: kind, oldNumber: old, newNumber: new, text: text, hunkIndex: hunk))
    }
    // An untracked file ending in a newline: drop the bare `+` that `split('\n')` leaves.
    if lines.last == "+", lines.count > 1, !lines.contains(where: { hunkStart($0) != nil }),
      lines.contains("--- /dev/null")
    {
      lines.removeLast()
    }
    for line in lines {
      if line == "Staged changes" || line == "Working changes" {
        working = line == "Working changes"
        add(.meta, line)
      } else if let (old, new) = hunkStart(line) {
        oldLine = old
        newLine = new
        inHunk = true
        add(.hunk, line, hunk: working ? workingHunks : nil)
        if working { workingHunks += 1 }
      } else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("\\")
        || (!inHunk && (line.hasPrefix("---") || line.hasPrefix("+++")))
      {
        if line.hasPrefix("diff ") {
          inHunk = false
          newFile = false
        }
        if line == "--- /dev/null" { newFile = true }
        if line.hasPrefix("+++"), newFile, newLine == 0 { newLine = 1 }
        add(.meta, line)
      } else if line.hasPrefix("+") {
        add(.added, line, new: take(&newLine))
      } else if line.hasPrefix("-") {
        add(.removed, line, old: take(&oldLine))
      } else {
        add(.context, line, old: take(&oldLine), new: take(&newLine))
      }
    }
    return rows
  }

  /// The counter's value, then one more. Nil while no hunk has set it, as Electron's `n ? n++ : ''`.
  private static func take(_ counter: inout Int) -> Int? {
    guard counter > 0 else { return nil }
    defer { counter += 1 }
    return counter
  }

  // Built once. NSRegularExpression is immutable and documented as thread-safe.
  static let hunkHeader = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)

  static func hunkStart(_ line: String) -> (Int, Int)? {
    guard let match = hunkHeader.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let old = Range(match.range(at: 1), in: line), let new = Range(match.range(at: 2), in: line)
    else { return nil }
    return (Int(line[old]) ?? 0, Int(line[new]) ?? 0)
  }
}

/// A file's kind, for its icon, as Electron's `fileIcon` in `WorkspacePages.tsx`.
public enum FileKind: Equatable, Sendable {
  case folder, code, document, other

  static let codeExtensions: Set<String> = [
    "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "go", "rb", "java", "c", "cpp", "h", "swift",
    "css", "scss", "html", "sh",
  ]
  static let documentExtensions: Set<String> = ["md", "mdx", "txt", "json", "yaml", "yml", "toml", "lock"]

  public static func of(name: String, directory: Bool) -> FileKind {
    if directory { return .folder }
    guard let dot = name.lastIndex(of: ".") else { return .other }
    let ext = name[name.index(after: dot)...].lowercased()
    if codeExtensions.contains(ext) { return .code }
    if documentExtensions.contains(ext) { return .document }
    return .other
  }

  public static func of(_ file: ProjectFile) -> FileKind { of(name: file.name, directory: file.directory) }

  /// An SF Symbol in place of Electron's lucide icons: Folder, FileCode2, FileText and File.
  public var symbol: String {
    switch self {
    case .folder: "folder"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .document: "doc.text"
    case .other: "doc"
    }
  }
}

/// One folder in the Files tab's path.
public struct Breadcrumb: Equatable, Sendable, Identifiable {
  public let name: String
  /// Relative to the project root.
  public let path: String
  public var id: String { path }

  /// The folders from the project root down to `directory`. The root itself is not one of them.
  public static func trail(_ directory: String) -> [Breadcrumb] {
    let parts = directory.split(separator: "/").map(String.init)
    return parts.indices.map { Breadcrumb(name: parts[$0], path: parts[...$0].joined(separator: "/")) }
  }

  /// The folder above `directory`, or `""` for the root.
  public static func parent(of directory: String) -> String {
    directory.split(separator: "/").dropLast().joined(separator: "/")
  }
}

/// A changed file's row in the Changes tab, as Electron draws it.
public enum ChangeLabel {
  /// `??` (untracked) shows as `U`.
  public static func status(_ change: GitChange) -> String { change.status == "??" ? "U" : change.status }

  public static func isDeleted(_ change: GitChange) -> Bool { change.status.contains("D") }

  public static func name(_ path: String) -> String {
    normalized(path).split(separator: "/").last.map(String.init) ?? path
  }

  /// The folder the file is in, or "Project root".
  public static func folder(_ path: String) -> String {
    let path = normalized(path)
    guard let slash = path.lastIndex(of: "/") else { return "Project root" }
    return String(path[..<slash])
  }

  /// Slashes forward, and no trailing one: an untracked folder arrives as `newdir/`.
  static func normalized(_ path: String) -> String {
    var path = path.replacingOccurrences(of: "\\", with: "/")
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}

/// The text of a project's Git badges, as Electron's project cards.
public enum GitBadge {
  public static func changes(_ status: GitStatus) -> String {
    status.changes.isEmpty ? "Clean" : "\(status.changes.count) changed"
  }

  /// "main · 3 changed", for the project picker. Nil outside a Git repository.
  public static func summary(_ status: GitStatus) -> String? {
    guard status.isRepository else { return nil }
    return status.branch.isEmpty ? changes(status) : "\(status.branch) · \(changes(status))"
  }
}

/// One row of the Activity tab, as Electron's `activityTitle` and the detail line in `Inspector.tsx`.
public struct ActivityEntry: Equatable, Sendable, Identifiable {
  public let id: String
  /// `inProgress`, `completed`, or a failure status.
  public let status: String
  public let title: String
  public let detail: String

  public static func build(_ items: [TranscriptItem]) -> [ActivityEntry] {
    items
      .filter { $0.retracted != true && !["userMessage", "agentMessage", "reasoning"].contains($0.kind) }
      .map { ActivityEntry(id: $0.itemId, status: $0.status, title: title($0), detail: detail($0)) }
  }

  static func title(_ item: TranscriptItem) -> String {
    if item.kind == "reminderChild" {
      return ToolPresentation.first(item.reminderAgentId).map { "Reminder · \($0)" } ?? "Background reminder"
    }
    if item.kind == "hookRun" { return ToolPresentation.first(item.label) ?? "CLI hook" }
    return ToolPresentation.first(item.tool, item.label) ?? titled(item.kind)
  }

  static func detail(_ item: TranscriptItem) -> String {
    if item.kind == "reminderChild" {
      return (item.blocking == true ? "Keeps the turn open · " : "")
        + (item.status == "inProgress" ? "Running" : item.status)
    }
    return ToolPresentation.first(item.statusLine, item.objective, item.fallbackText) ?? item.status
  }

  /// `webSearch` becomes `Web Search`: a space before each capital, and a capital first letter.
  static func titled(_ kind: String) -> String {
    let spaced = kind.reduce(into: "") { text, character in
      if character.isUppercase { text += " " }
      text.append(character)
    }
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
  }
}

public enum FilePreview {
  /// As Electron's line count: `content.split('\n').length`, or 0 for empty content. Counts bytes,
  /// because Swift reads "\r\n" as one `Character` that is not "\n".
  public static func lineCount(_ text: String) -> Int {
    text.isEmpty ? 0 : text.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
  }
}
