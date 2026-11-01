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

  private static func available(_ skills: [SkillRow]) -> [SkillRow] {
    skills.filter { !commandNames.contains($0.selector.lowercased()) }
  }

  /// Skill selectors also hold digits, `_` and `:`, which a command name does not.
  private static func isSelectorScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ":": true
    default: false
    }
  }

  public static func rows(for draft: String, skills: [SkillRow]) -> [SlashRow] {
    let commands = ComposerCommand.menu(for: draft).map {
      SlashRow(name: $0.name, description: $0.description)
    }
    let scalars = draft.unicodeScalars
    guard scalars.first == "/", scalars.dropFirst().allSatisfy(isSelectorScalar) else {
      return commands
    }
    let typed = String(scalars.dropFirst()).lowercased()
    return commands
      + available(skills).filter { $0.selector.lowercased().hasPrefix(typed) }.map {
        SlashRow(name: $0.selector, description: $0.description)
      }
  }

  /// The skill the whole draft names, or nil. The first word must be a known selector.
  public static func invocation(_ draft: String, skills: [SkillRow]) -> SkillInvocation? {
    let text = JSWhitespace.trim(draft).unicodeScalars
    guard text.first == "/" else { return nil }
    let start = text.index(after: text.startIndex)
    var end = start
    while end < text.endIndex, isSelectorScalar(text[end]) { end = text.index(after: end) }
    guard end > start, end == text.endIndex || JSWhitespace.contains(text[end]) else { return nil }
    let name = String(text[start..<end])
    guard available(skills).contains(where: { $0.selector == name }) else { return nil }
    return SkillInvocation(selector: name, arguments: JSWhitespace.trim(String(text[end...])))
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
      if menu.contains(where: { "/\($0.name)".lowercased() == draft.lowercased() }) {
        return .submit
      }
      return .setDraft("/\(menu[index].name) ")
    case .escape:
      return .setDraft(draft + " ")
    }
  }
}
