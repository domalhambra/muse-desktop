import Foundation
import MuseBackend

/// The answers being written for one Muse question, as Electron's `QuestionCard`.
public struct QuestionForm: Equatable, Sendable {
  public let question: UserQuestion
  private var answers: [String: QuestionAnswer] = [:]

  public init(_ question: UserQuestion) { self.question = question }

  func prompt(_ id: String) -> UserQuestion.Prompt? { question.questions.first { $0.id == id } }

  /// Chooses or toggles an option. Choosing clears any free text for that prompt.
  public mutating func choose(_ label: String, in promptId: String) {
    guard let prompt = prompt(promptId) else { return }
    if prompt.selection.mode == "multiple" {
      var labels = answers[promptId]?.selectedLabels ?? []
      if let index = labels.firstIndex(of: label) { labels.remove(at: index) } else { labels.append(label) }
      answers[promptId] = QuestionAnswer(questionId: promptId, selectedLabels: labels)
    } else {
      answers[promptId] = QuestionAnswer(questionId: promptId, selectedLabel: label)
    }
  }

  /// The backend's free-text limit, in UTF-16 units.
  public static let freeTextLimit = 500

  /// Writes free text, up to the limit. Writing clears any selection for that prompt.
  public mutating func write(_ text: String, in promptId: String) {
    answers[promptId] = QuestionAnswer(
      questionId: promptId, freeText: text.prefix(utf16Units: Self.freeTextLimit))
  }

  public func isChosen(_ label: String, in promptId: String) -> Bool {
    let answer = answers[promptId]
    return answer?.selectedLabel == label || answer?.selectedLabels?.contains(label) == true
  }

  public func freeText(in promptId: String) -> String { answers[promptId]?.freeText ?? "" }

  /// Every prompt has free text, a single choice, or a number of choices within its limits.
  public var canContinue: Bool {
    question.questions.allSatisfy { prompt in
      guard let answer = answers[prompt.id] else { return false }
      if answer.freeText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
      if answer.selectedLabel != nil { return true }
      let count = answer.selectedLabels?.count ?? 0
      return prompt.selection.mode == "multiple"
        && count >= (prompt.selection.minSelections ?? 1)
        && count <= (prompt.selection.maxSelections ?? Int.max)
    }
  }

  /// The answers in prompt order. Free text is sent untrimmed, as Electron does.
  public var submission: [QuestionAnswer] { question.questions.compactMap { answers[$0.id] } }
}

/// Labels for approval cards, as Electron's `ApprovalCard`.
public enum ApprovalPresentation {
  public static func heading(_ approval: Approval) -> String {
    "Muse would like permission to use \(approval.toolName)."
  }

  public static func subject(_ approval: Approval) -> String {
    let subject = approval.subject
    return ToolPresentation.first(subject.command, subject.path, subject.host, subject.target) ?? approval.rawArgs
  }

  public static func isPrimary(_ choice: Approval.Choice) -> Bool { choice.decision.hasPrefix("approved") }

  public static func savesRule(_ choice: Approval.Choice) -> Bool { choice.scope == "localPersistent" }

  public static func help(_ choice: Approval.Choice) -> String {
    if let preview = choice.rulePreview, !preview.isEmpty { return preview }
    switch choice.scope {
    case "once": return "Applies once"
    case "session": return "Applies for this session"
    default: return "Applies as a saved policy"
    }
  }
}
