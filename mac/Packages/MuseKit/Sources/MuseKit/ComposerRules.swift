import Foundation
import MuseBackend

// The composer's rules: the drop plan, the slash commands and the `@` mentions. Electron keeps
// them in src/renderer/src/commands.ts and components/Composer.tsx.

/// JavaScript's whitespace: what `\s` matches and `String.prototype.trim` removes. The rules
/// ported from Electron's regular expressions use it, so they match the same drafts. Swift's
/// `.whitespacesAndNewlines` differs (it has U+0085, and lacks U+FEFF).
enum JSWhitespace {
  static func contains(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
      true
    default:
      false
    }
  }

  /// `text.trim()`.
  static func trim(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard let first = scalars.firstIndex(where: { !contains($0) }),
      let last = scalars.lastIndex(where: { !contains($0) })
    else { return "" }
    return String(scalars[first...last])
  }

  /// `/\s$/.test(text)`.
  static func endsWithWhitespace(_ text: String) -> Bool {
    text.unicodeScalars.last.map(contains) ?? false
  }
}

/// What a drop on the composer does. Electron pastes a dropped file's text, or `@<file name>`,
/// into the draft. mMac attaches files as chips, with the paperclip's limits, and turns a folder
/// inside the project into a mention of its project-relative path.
public struct DropPlan: Equatable, Sendable {
  public static let folderError = "Drop files, or a folder inside this project."

  /// Files to attach as chips.
  public var files: [URL]
  /// `@<project-relative path>/` for each folder inside the project.
  public var mentions: [String]
  /// Set when a folder is outside the project, is the project itself, or no project is chosen.
  public var error: String?

  public init(files: [URL] = [], mentions: [String] = [], error: String? = nil) {
    self.files = files
    self.mentions = mentions
    self.error = error
  }

  /// Sorts dropped URLs. A folder is told from a file on disk, so a folder URL without its
  /// trailing slash still counts. Both paths have their symbolic links resolved before the
  /// comparison.
  public static func classify(_ urls: [URL], project: String) -> DropPlan {
    var plan = DropPlan()
    let root = project.isEmpty
      ? nil : URL(filePath: project, directoryHint: .isDirectory).resolvingSymlinksInPath().path
    for url in urls where url.isFileURL {
      // Resolved first, so a link to a folder is a folder.
      let resolved = url.resolvingSymlinksInPath()
      let isFolder = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
      guard isFolder else {
        plan.files.append(url)
        continue
      }
      let path = resolved.path
      if let root, path.hasPrefix(root + "/") {
        plan.mentions.append("@\(path.dropFirst(root.count + 1))/")
      } else {
        plan.error = folderError
      }
    }
    return plan
  }

  /// The draft with the mentions at its end, after one space when the draft does not end in
  /// whitespace. The last mention ends in `/`, so the mention menu opens on that folder.
  public func appendingMentions(to draft: String) -> String {
    guard !mentions.isEmpty else { return draft }
    let gap = draft.isEmpty || JSWhitespace.endsWithWhitespace(draft) ? "" : " "
    return draft + gap + mentions.joined(separator: " ")
  }
}

/// A composer command and its argument, as Electron's `parseComposerCommand` returns them.
public struct ParsedCommand: Equatable, Sendable {
  /// Lowercased. It may name no command; `Workspace.run(_:)` refuses those.
  public let name: String
  /// Trimmed, or empty. It may hold newlines.
  public let argument: String

  public init(name: String, argument: String) {
    self.name = name
    self.argument = argument
  }
}

/// A key the composer's popups handle. Return and Enter are `.enter` only without Shift, and
/// only when no IME text is being composed; the view checks both before asking.
public enum SlashKey: Sendable {
  case down, up, tab, enter, escape
}

/// What a key does while the command menu may be open.
public enum SlashKeyAction: Equatable, Sendable {
  /// The menu is closed: the key does what it does in the text view.
  case pass
  /// Move the highlight to this row.
  case select(Int)
  /// Replace the draft.
  case setDraft(String)
  /// Enter on a whole command name: send the draft as usual, which runs it.
  case submit
}

/// The ten composer commands, in Electron's menu order (src/renderer/src/commands.ts).
public enum ComposerCommand: String, CaseIterable, Sendable, Identifiable {
  case clear, new, voice, model, effort, compact, rename, stop, settings, help

  public var id: String { rawValue }
  public var name: String { rawValue }

  public var description: String {
    switch self {
    case .clear: "Start a new conversation; keep saved history"
    case .new: "Start a new conversation"
    case .voice: "Start voice input"
    case .model: "Choose a model, or /model <model-id>"
    case .effort: "Choose reasoning effort, or /effort <level>"
    case .compact: "Compact this conversation with Muse Code"
    case .rename: "/rename <conversation name>"
    case .stop: "Stop Muse\u{2019}s active turn"
    case .settings: "Open desktop settings"
    case .help: "Open the guide and CLI compatibility information"
    }
  }

  /// The menu for this draft. Electron's rule: the whole draft, untrimmed, matches `^\/[a-z-]*$`
  /// (case-insensitive, ASCII letters only), and the list keeps the commands whose name starts
  /// with the lowercased text after the slash. Checked by hand: ICU's `$` would also match before
  /// a final newline, and JavaScript's does not.
  public static func menu(for draft: String) -> [ComposerCommand] {
    let scalars = draft.unicodeScalars
    guard scalars.first == "/", scalars.dropFirst().allSatisfy(isNameScalar) else { return [] }
    let typed = String(scalars.dropFirst()).lowercased()
    return allCases.filter { $0.name.hasPrefix(typed) }
  }

  /// Electron's `/^\/([a-z-]+)(?:\s+([\s\S]*))?$/i` on the trimmed draft. The name is
  /// lowercased; the argument is trimmed, or empty.
  public static func parse(_ draft: String) -> ParsedCommand? {
    let text = JSWhitespace.trim(draft).unicodeScalars
    guard text.first == "/" else { return nil }
    let nameStart = text.index(after: text.startIndex)
    var index = nameStart
    while index < text.endIndex, isNameScalar(text[index]) { index = text.index(after: index) }
    guard index > nameStart else { return nil }
    let name = String(text[nameStart..<index]).lowercased()
    guard index < text.endIndex else { return ParsedCommand(name: name, argument: "") }
    // Whitespace must follow the name; everything after it is the argument.
    guard JSWhitespace.contains(text[index]) else { return nil }
    return ParsedCommand(name: name, argument: JSWhitespace.trim(String(text[index...])))
  }

  /// Electron's keys while the menu is open. Down and Up wrap. Tab fills the highlighted command
  /// and a space. Enter does the same, unless the draft already is a whole command name, which it
  /// runs. Escape adds a space, so the menu closes and the draft stays.
  public static func slashKeyAction(_ key: SlashKey, draft: String, index: Int) -> SlashKeyAction {
    let menu = menu(for: draft)
    guard !menu.isEmpty else { return .pass }
    let index = min(max(index, 0), menu.count - 1)
    switch key {
    case .down:
      return .select((index + 1) % menu.count)
    case .up:
      return .select((index - 1 + menu.count) % menu.count)
    case .tab:
      return .setDraft("/\(menu[index].name) ")
    case .enter:
      let lowered = draft.lowercased()
      if allCases.contains(where: { "/\($0.name)" == lowered }) { return .submit }
      return .setDraft("/\(menu[index].name) ")
    case .escape:
      return .setDraft(draft + " ")
    }
  }

  /// `[a-z-]` with the `i` flag: ASCII letters of either case, and the hyphen.
  static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "-": true
    default: false
    }
  }
}

/// Muse's four approval modes, in the SDK's order (`ApprovalMode` in msp.d.ts). Closed: a client
/// selects one; it never defines one. The labels are Muse's own names as words, by Dom's decision.
public enum ApprovalMode: String, CaseIterable, Sendable, Identifiable {
  case allowAll, promptUnmatched, onRequest, denyUnmatched

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .allowAll: "Allow all"
    case .promptUnmatched: "Prompt unmatched"
    case .onRequest: "On request"
    case .denyUnmatched: "Deny unmatched"
    }
  }

  /// The label for a raw mode name. A mode this list does not know shows as its name.
  public static func label(for rawValue: String) -> String {
    ApprovalMode(rawValue: rawValue)?.label ?? rawValue
  }
}

/// The composer's `!` escape, as the Muse TUI's: a draft whose first non-whitespace character is
/// `!` runs the rest as a shell command in the conversation's folder, through `session/userShell`.
public enum ShellRule {
  /// The command, trimmed, or nil when the draft is not a shell command or the command is empty.
  public static func command(in draft: String) -> String? {
    let text = JSWhitespace.trim(draft)
    guard text.first == "!" else { return nil }
    let command = JSWhitespace.trim(String(text.dropFirst()))
    return command.isEmpty ? nil : command
  }
}

/// An `@` mention at the end of the draft.
public struct Mention: Equatable, Sendable {
  /// The draft before the `@`.
  public let prefix: String
  /// What follows the `@`, to the end of the draft.
  public let token: String
  /// The token before its last `/`, or empty: the folder the menu lists.
  public let directory: String
  /// The token after its last `/`: it filters the folder's names.
  public let filter: String

  public init(prefix: String, token: String, directory: String, filter: String) {
    self.prefix = prefix
    self.token = token
    self.directory = directory
    self.filter = filter
  }
}

/// What a key does while the mention menu shows rows.
public enum MentionKeyAction: Equatable, Sendable {
  case pass
  case select(Int)
  /// Insert this row with `MentionRule.insert(_:into:)`.
  case choose(Int)
  /// Escape: close the menu until the folder changes.
  case dismiss
}

/// Electron's `@` rule (Composer.tsx). The CLI reads the inserted path; mMac sends it as text.
public enum MentionRule {
  public static let maxRows = 12

  /// `/(?:^|\s)@([^\s@]*)$/` on the whole draft: the `@` starts the draft or follows whitespace,
  /// and the token runs to the end. The caret is ignored, as in Electron.
  public static func match(_ draft: String) -> Mention? {
    let scalars = draft.unicodeScalars
    var start = scalars.endIndex
    while start > scalars.startIndex {
      let before = scalars.index(before: start)
      let scalar = scalars[before]
      if scalar == "@" || JSWhitespace.contains(scalar) { break }
      start = before
    }
    guard start > scalars.startIndex else { return nil }
    let at = scalars.index(before: start)
    guard scalars[at] == "@" else { return nil }
    if at > scalars.startIndex, !JSWhitespace.contains(scalars[scalars.index(before: at)]) { return nil }
    let token = String(scalars[start...])
    let prefix = String(scalars[..<at])
    guard let slash = token.lastIndex(of: "/") else {
      return Mention(prefix: prefix, token: token, directory: "", filter: token)
    }
    return Mention(
      prefix: prefix, token: token, directory: String(token[..<slash]),
      filter: String(token[token.index(after: slash)...]))
  }

  /// The folder's entries whose name contains the filter, any case, at most 12. The path is not
  /// searched.
  public static func rows(_ files: [ProjectFile], filter: String) -> [ProjectFile] {
    let needle = filter.lowercased()
    return Array(files.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }.prefix(maxRows))
  }

  /// The draft with the mention replaced by the entry's project-relative path: a space after a
  /// file ends the mention, and a `/` after a folder keeps the menu open in it.
  public static func insert(_ file: ProjectFile, into draft: String) -> String {
    guard let mention = match(draft) else { return draft }
    return mention.prefix + "@" + file.path + (file.directory ? "/" : " ")
  }

  /// Down and Up wrap; Tab and Enter choose; Escape closes.
  public static func keyAction(_ key: SlashKey, index: Int, count: Int) -> MentionKeyAction {
    guard count > 0 else { return .pass }
    let index = min(max(index, 0), count - 1)
    switch key {
    case .down: return .select((index + 1) % count)
    case .up: return .select((index - 1 + count) % count)
    case .tab, .enter: return .choose(index)
    case .escape: return .dismiss
    }
  }
}
