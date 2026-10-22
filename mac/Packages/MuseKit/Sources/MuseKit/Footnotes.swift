import Foundation

/// GFM footnotes, which swift-markdown does not parse. remark-gfm draws a reference `[^a]` as a
/// small number and lists the notes at the end. This rewrites the source before parsing: each
/// reference becomes a superscript number, in order of first use, and the definitions used become
/// a numbered list after a rule. Code blocks and code spans are left alone. An unused definition
/// is dropped, and a reference with no definition stays as typed, as in remark-gfm. Labels ignore
/// case, as in GFM.
enum Footnotes {
  // Built once. NSRegularExpression is immutable and documented as thread-safe.
  static let definition = try! NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]?(.*)$"#)
  static let reference = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
  static let superscripts: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]

  /// A code fence: three or more backticks or tildes. It closes on a line of at least as many of
  /// the same mark and nothing else.
  struct Fence: Equatable {
    let mark: Character
    let length: Int

    init?(opening line: String) {
      let trimmed = line.drop { $0 == " " }
      guard let mark = trimmed.first, mark == "`" || mark == "~" else { return nil }
      let length = trimmed.prefix { $0 == mark }.count
      // A backtick fence's info string has no backtick: "```a``` b" is a code span.
      guard length >= 3, mark == "~" || !trimmed.dropFirst(length).contains("`") else { return nil }
      self.mark = mark
      self.length = length
    }

    func isClosed(by line: String) -> Bool {
      let trimmed = line.drop { $0 == " " }
      let run = trimmed.prefix { $0 == mark }.count
      return run >= length && trimmed.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    var closing: String { String(repeating: mark, count: length) }
  }

  static func rewrite(_ original: String) -> String {
    guard original.contains("[^") else { return original }
    // Windows line ends would leave a "\r" on every line, which no fence or definition matches.
    let source = original.replacingOccurrences(of: "\r\n", with: "\n")
    // The lines that stay, each marked when it is inside a fenced code block.
    var body: [(line: String, code: Bool)] = []
    var definitions: [String: String] = [:]
    var fence: Fence?
    // The definition the next indented line continues. `keep` is false for an ignored duplicate,
    // whose continuation lines are dropped with it.
    var continuing: (label: String, keep: Bool)?
    for line in source.components(separatedBy: "\n") {
      if let open = fence {
        body.append((line, true))
        if open.isClosed(by: line) { fence = nil }
        continue
      }
      if let open = Fence(opening: line) {
        fence = open
        continuing = nil
        body.append((line, true))
        continue
      }
      if let groups = captures(definition, line) {
        let label = groups[0].lowercased()
        let stored = definitions[label] == nil
        if stored { definitions[label] = groups[1] }
        continuing = (label, stored)
        continue
      }
      // An indented line right after a definition continues it.
      if let (label, keep) = continuing, line.hasPrefix("    ") || line.hasPrefix("\t") {
        if keep { definitions[label, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }
        continue
      }
      continuing = nil
      body.append((line, false))
    }
    guard !definitions.isEmpty else { return original }

    var order: [String] = []
    let rewritten = body.map { line, code -> String in
      if code { return line }
      return replacingReferences(in: line) { typed in
        let label = typed.lowercased()
        guard definitions[label] != nil else { return nil }
        if !order.contains(label) { order.append(label) }
        return superscript(order.firstIndex(of: label)! + 1)
      }
    }
    var text = rewritten.joined(separator: "\n")
    guard !order.isEmpty else { return text }
    // A fence still open, say in a reply still streaming, would swallow the notes.
    if let open = fence { text += "\n" + open.closing }
    let notes = order.enumerated().map { "\($0.offset + 1). \(definitions[$0.element] ?? "")" }
    return text + "\n\n---\n\n" + notes.joined(separator: "\n") + "\n"
  }

  /// Replaces references outside code spans. A span opened by a run of N backticks closes on the
  /// next run of exactly N; a run with no match is plain text.
  static func replacingReferences(in line: String, _ replacement: (String) -> String?) -> String {
    guard line.contains("[^") else { return line }
    var result = ""
    var text = ""
    var index = line.startIndex
    while index < line.endIndex {
      guard line[index] == "`" else {
        text.append(line[index])
        index = line.index(after: index)
        continue
      }
      let run = backtickRunEnd(line, from: index)
      if let close = closingRun(line, from: run, length: line.distance(from: index, to: run)) {
        result += replacingMatches(in: text, replacement) + line[index..<close]
        text = ""
        index = close
      } else {
        text += line[index..<run]
        index = run
      }
    }
    return result + replacingMatches(in: text, replacement)
  }

  /// The end of the run of backticks that starts at `start`.
  static func backtickRunEnd(_ line: String, from start: String.Index) -> String.Index {
    line[start...].firstIndex { $0 != "`" } ?? line.endIndex
  }

  /// The end of the first run of exactly `length` backticks from `start`, or nil.
  static func closingRun(_ line: String, from start: String.Index, length: Int) -> String.Index? {
    var index = start
    while let open = line[index...].firstIndex(of: "`") {
      let end = backtickRunEnd(line, from: open)
      if line.distance(from: open, to: end) == length { return end }
      index = end
    }
    return nil
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
