import Foundation
import MuseBackend

/// One row of the transcript. Electron's rules are in `src/renderer/src/components/Transcript.tsx`.
public enum TranscriptEntry: Identifiable, Equatable, Sendable {
  case user(TranscriptItem)
  case agent(TranscriptItem)
  case reasoning(TranscriptItem)
  case tool(TranscriptItem)
  /// Three or more completed tools in a row.
  case toolGroup([TranscriptItem])

  public var id: String {
    switch self {
    case .user(let item), .agent(let item), .reasoning(let item), .tool(let item): item.itemId
    case .toolGroup(let items): "group-\(items.first?.itemId ?? "empty")"
    }
  }

  public static func build(_ items: [TranscriptItem]) -> [TranscriptEntry] {
    var entries: [TranscriptEntry] = []
    var run: [TranscriptItem] = []
    func flush() {
      if run.count >= 3 { entries.append(.toolGroup(run)) } else { entries += run.map(TranscriptEntry.tool) }
      run = []
    }
    for item in items where item.retracted != true && !Activity.isInternal(item) {
      switch item.kind {
      case "userMessage":
        flush()
        entries.append(.user(item))
      case "agentMessage":
        flush()
        entries.append(.agent(item))
      case "reasoning":
        flush()
        entries.append(.reasoning(item))
      default:
        if item.status == "completed" {
          run.append(item)
        } else {
          flush()
          entries.append(.tool(item))
        }
      }
    }
    flush()
    return entries
  }
}

/// Background work that shows only in the Activity inspector (M2), never in the transcript.
public enum Activity {
  public static func isInternal(_ item: TranscriptItem) -> Bool {
    item.kind == "reminderChild" || item.kind == "hookRun"
  }

  /// True when something runs and all of it is internal: "Finishing background tasks…".
  public static func isBackgroundOnly(_ items: [TranscriptItem]) -> Bool {
    let active = items.filter { $0.retracted != true && $0.status == "inProgress" }
    return !active.isEmpty && active.allSatisfy(isInternal)
  }
}

/// The labels of transcript rows. JavaScript's `a || b` skips empty strings, so `first` does too.
public enum ToolPresentation {
  static func first(_ values: String?...) -> String? {
    values.first { $0?.isEmpty == false } ?? nil
  }

  /// `toolCall` becomes `tool call`.
  static func spaced(_ kind: String) -> String {
    kind.reduce(into: "") { text, character in
      if character.isUppercase { text += " " + character.lowercased() } else { text.append(character) }
    }
  }

  public static func title(_ item: TranscriptItem) -> String {
    first(item.tool, item.label, item.role) ?? spaced(item.kind)
  }

  public static func summary(_ item: TranscriptItem) -> String? {
    first(item.statusLine, item.objective, item.commandText, item.fallbackText)
  }

  /// `stored` is the full output read with "Read stored output", when there is one.
  public static func output(_ item: TranscriptItem, stored: String?) -> String? {
    first(stored, item.visibleOutput, item.result?.text, item.failureReason, item.finalSummary)
  }

  /// Pretty-printed JSON, or `args` unchanged when it is not JSON. Electron's
  /// `JSON.stringify(value, null, 2)` keeps key order and writes `"b": 1`; this sorts keys and
  /// writes `"b" : 1`. Numbers go through `JSONEncoder`, which prints 0.7 as 0.7, as JavaScript does.
  public static func formattedArgs(_ args: String) -> String {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(args.utf8)),
      let pretty = try? argsEncoder.encode(value)
    else { return args }
    let text = String(decoding: pretty, as: UTF8.self)
    // Foundation writes an empty object or array over three lines; JSON.stringify writes {} and [].
    // The encoder escapes every newline inside a string, so a bare newline is always layout.
    return emptyContainer.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1$2")
  }

  // Built once. NSRegularExpression is immutable and documented as thread-safe.
  static let emptyContainer = try! NSRegularExpression(pattern: #"([{\[])\n\s*([}\]])"#)

  static let argsEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// `+3 −1`, with the minus sign U+2212, whenever the tool has a patch summary, even `+0 −0`,
  /// as in Electron. nil when it has none.
  public static func patch(_ item: TranscriptItem) -> String? {
    guard let patch = item.patchSummary else { return nil }
    return "+\(patch.added) \u{2212}\(patch.removed)"
  }

  public static func footer(_ item: TranscriptItem) -> String {
    guard let duration = item.durationMs else { return item.status }
    return "\(item.status) · \(fixed1(duration / 1000))s"
  }

  /// JavaScript's `toFixed(1)`: the exact binary value rounded, with a tie away from zero.
  /// `%.1f` rounds the exact value too, but breaks a tie to even. A tie needs the value to be
  /// an odd number of quarters (1.25, 0.75), and four times a double is exact, so only those
  /// round half away from zero here. 1.15 is really 1.1499…, so it stays 1.1, as in Electron.
  static func fixed1(_ value: Double) -> String {
    let quarters = value * 4
    let tie = quarters.rounded() == quarters && quarters.truncatingRemainder(dividingBy: 2) != 0
    let rounded = tie ? (value * 10).rounded(.toNearestOrAwayFromZero) / 10 : value
    return String(format: "%.1f", rounded)
  }

  public static func groupTitle(_ items: [TranscriptItem]) -> String { "Ran \(items.count) tools" }

  public static func groupDetail(_ items: [TranscriptItem]) -> String {
    var titles: [String] = []
    for item in items where !titles.contains(title(item)) { titles.append(title(item)) }
    return titles.prefix(3).joined(separator: ", ")
  }

  public static func groupPatch(_ items: [TranscriptItem]) -> String? {
    let added = items.compactMap(\.patchSummary?.added).reduce(0, +)
    let removed = items.compactMap(\.patchSummary?.removed).reduce(0, +)
    return added > 0 || removed > 0 ? "+\(added) \u{2212}\(removed)" : nil
  }

  /// A user message as plain text, with injected tags removed.
  public static func messageText(_ item: TranscriptItem) -> String {
    first(SessionTitle.stripInjectedTags(first(item.displayText, item.text)), item.displayText, item.text) ?? ""
  }

  public static func reasoningText(_ item: TranscriptItem) -> String {
    first((item.summary ?? []).joined(separator: "\n\n"), item.text)
      ?? "No reasoning text was provided by the model."
  }
}
