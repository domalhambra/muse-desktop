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
    case .toolGroup(let items): "group-\(items[0].itemId)"
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

  public static func formattedArgs(_ args: String) -> String {
    guard let data = args.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    else { return args }
    return String(decoding: pretty, as: UTF8.self)
  }

  /// `+3 −1`, with the minus sign U+2212, or nil when nothing changed.
  public static func patch(_ item: TranscriptItem) -> String? {
    guard let patch = item.patchSummary, patch.added > 0 || patch.removed > 0 else { return nil }
    return "+\(patch.added) \u{2212}\(patch.removed)"
  }

  public static func footer(_ item: TranscriptItem) -> String {
    guard let duration = item.durationMs else { return item.status }
    return "\(item.status) · \(String(format: "%.1f", duration / 1000))s"
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
