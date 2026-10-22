import Foundation

/// GFM footnotes, which swift-markdown does not parse. remark-gfm draws a reference `[^a]` as a
/// small number and lists the notes at the end. This rewrites the source before parsing: each
/// reference becomes a superscript number, in order of first use, and the definitions used become
/// a numbered list after a rule. Code blocks and code spans are left alone. An unused definition
/// is dropped, and a reference with no definition stays as typed, as in remark-gfm.
enum Footnotes {
  // Built once. NSRegularExpression is immutable and documented as thread-safe.
  static let definition = try! NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]?(.*)$"#)
  static let reference = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
  static let superscripts: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]

  static func rewrite(_ source: String) -> String {
    guard source.contains("[^") else { return source }
    var body: [String] = []
    var definitions: [String: String] = [:]
    var fence: Substring?
    var continuing: String?
    for line in source.components(separatedBy: "\n") {
      let trimmed = line.drop { $0 == " " }
      if let open = fence {
        body.append(line)
        if trimmed.hasPrefix(open) { fence = nil }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = trimmed.prefix(3)
        continuing = nil
        body.append(line)
        continue
      }
      if let groups = captures(definition, line) {
        if definitions[groups[0]] == nil { definitions[groups[0]] = groups[1] }
        continuing = groups[0]
        continue
      }
      // An indented line right after a definition continues it.
      if let label = continuing, line.hasPrefix("    ") || line.hasPrefix("\t") {
        definitions[label, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
        continue
      }
      continuing = nil
      body.append(line)
    }
    guard !definitions.isEmpty else { return source }

    var order: [String] = []
    fence = nil
    let rewritten = body.map { line -> String in
      let trimmed = line.drop { $0 == " " }
      if let open = fence {
        if trimmed.hasPrefix(open) { fence = nil }
        return line
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = trimmed.prefix(3)
        return line
      }
      return replacingReferences(in: line) { label in
        guard definitions[label] != nil else { return nil }
        if !order.contains(label) { order.append(label) }
        return superscript(order.firstIndex(of: label)! + 1)
      }
    }
    let text = rewritten.joined(separator: "\n")
    guard !order.isEmpty else { return text }
    let notes = order.enumerated().map { "\($0.offset + 1). \(definitions[$0.element] ?? "")" }
    return text + "\n\n---\n\n" + notes.joined(separator: "\n") + "\n"
  }

  /// Replaces references outside code spans. A span is text between backticks.
  static func replacingReferences(in line: String, _ replacement: (String) -> String?) -> String {
    guard line.contains("[^") else { return line }
    return line.components(separatedBy: "`").enumerated().map { index, part in
      index % 2 == 1 ? part : replacingMatches(in: part, replacement)
    }.joined(separator: "`")
  }

  static func replacingMatches(in text: String, _ replacement: (String) -> String?) -> String {
    let matches = reference.matches(in: text, range: NSRange(text.startIndex..., in: text))
    // Numbered in reading order, then replaced from the end, so earlier ranges stay valid.
    let found = matches.compactMap { match -> (Range<String.Index>, String)? in
      guard let whole = Range(match.range, in: text), let label = Range(match.range(at: 1), in: text),
        let new = replacement(String(text[label]))
      else { return nil }
      return (whole, new)
    }
    var result = text
    for (range, new) in found.reversed() { result.replaceSubrange(range, with: new) }
    return result
  }

  static func superscript(_ number: Int) -> String {
    String(String(number).compactMap { $0.wholeNumberValue.map { superscripts[$0] } })
  }

  static func captures(_ expression: NSRegularExpression, _ line: String) -> [String]? {
    guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
      return nil
    }
    return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
  }
}
