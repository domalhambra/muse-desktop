import MuseBackend

/// A skill the draft asks to run.
public struct SkillInvocation: Equatable, Sendable {
  public let selector: String
  public let arguments: String
  public init(selector: String, arguments: String) {
    self.selector = selector
    self.arguments = arguments
  }
}

/// One row of the `/` popup.
public struct SlashRow: Equatable, Sendable, Identifiable {
  public let name: String
  public let description: String
  public var id: String { name }
}

/// The `/` popup's rows and keys: the commands, as `ComposerCommand` rules them, then the skills.
/// A skill named like a command is left out, so the command wins.
public enum SlashMenu {
  private static let commandNames = Set(ComposerCommand.allCases.map(\.name))

  /// The skills a draft can name. A skill whose first word is a command name is left out, so
  /// `/clear cache` stays the command `/clear`.
  private static func available(_ skills: [SkillRow]) -> [SkillRow] {
    skills.filter {
      !$0.selector.isEmpty && !commandNames.contains(firstWord($0.selector).lowercased())
    }
  }

  private static func firstWord(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.prefix { !JSWhitespace.contains($0) }))
  }

  public static func rows(for draft: String, skills: [SkillRow]) -> [SlashRow] {
    let commands = ComposerCommand.menu(for: draft).map {
      SlashRow(name: $0.name, description: $0.description)
    }
    guard draft.unicodeScalars.first == "/" else { return commands }
    let typed = String(draft.unicodeScalars.dropFirst()).lowercased()
    return commands
      + available(skills).filter { $0.selector.lowercased().hasPrefix(typed) }.map {
        SlashRow(name: $0.selector, description: $0.description)
      }
  }

  /// The skill the whole draft names, or nil. The draft starts with the longest known selector,
  /// matched without case, and the selector ends at whitespace or at the end of the draft. The
  /// result carries the selector as the skill lists it.
  public static func invocation(_ draft: String, skills: [SkillRow]) -> SkillInvocation? {
    let text = JSWhitespace.trim(draft)
    guard text.unicodeScalars.first == "/" else { return nil }
    let rest = String(text.unicodeScalars.dropFirst())
    guard !commandNames.contains(firstWord(rest).lowercased()) else { return nil }
    var best: (row: SkillRow, tail: Substring)?
    for row in available(skills) {
      guard let range = rest.range(of: row.selector, options: [.anchored, .caseInsensitive]) else {
        continue
      }
      let tail = rest[range.upperBound...]
      guard tail.unicodeScalars.first.map(JSWhitespace.contains) ?? true else { continue }
      if best == nil || row.selector.count > best!.row.selector.count { best = (row, tail) }
    }
    guard let best else { return nil }
    return SkillInvocation(selector: best.row.selector, arguments: JSWhitespace.trim(String(best.tail)))
  }

  /// `ComposerCommand.slashKeyAction`'s keys, over both kinds of row.
  public static func keyAction(
    _ key: SlashKey, draft: String, index: Int, skills: [SkillRow]
  ) -> SlashKeyAction {
    let menu = rows(for: draft, skills: skills)
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
      // A whole name runs when the highlight is on row 0 or on that name's row. Index 0 cannot
      // tell an untouched highlight from one moved back to it, so row 0 always counts as untouched.
      if let exact = menu.firstIndex(where: { "/\($0.name)".lowercased() == draft.lowercased() }),
        index == 0 || index == exact
      {
        return .submit
      }
      return .setDraft("/\(menu[index].name) ")
    case .escape:
      return .setDraft(draft + " ")
    }
  }
}
