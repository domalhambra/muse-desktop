import Foundation
import MuseBackend
import Observation
import SwiftUI

/// Asks wait here and show one at a time, as window sheets.
@MainActor @Observable
final class AskQueue {
  struct Pending: Identifiable {
    /// Its own id, not the Ask's: a restarted backend numbers its Asks from 1 again.
    let id = UUID()
    let ask: Ask
    let continuation: CheckedContinuation<Int, Never>
  }

  private(set) var current: Pending?
  private var waiting: [Pending] = []
  /// Bumped by `cancelAll`. A backend's Asks carry the generation it started in.
  private(set) var generation = 0

  /// Shows `ask` when every earlier one is answered, and returns the chosen button's index.
  /// An Ask from an older generation, whose backend the queue was cancelled for, returns -1.
  func present(_ ask: Ask, generation: Int) async -> Int {
    guard generation == self.generation else { return -1 }
    return await withCheckedContinuation { continuation in
      let pending = Pending(ask: ask, continuation: continuation)
      if current == nil { current = pending } else { waiting.append(pending) }
    }
  }

  /// Answers the Ask with `id` if it is still the one shown. A sheet that is closing, or a key
  /// press handled twice, cannot answer the next Ask by mistake.
  func answer(_ choice: Int, to id: UUID) {
    guard let current, current.id == id else { return }
    current.continuation.resume(returning: choice)
    self.current = waiting.isEmpty ? nil : waiting.removeFirst()
  }

  /// Answers every waiting Ask with -1, the cancel choice. Used when the backend stops.
  func cancelAll() {
    generation += 1
    let all = (current.map { [$0] } ?? []) + waiting
    current = nil
    waiting = []
    for pending in all { pending.continuation.resume(returning: -1) }
  }
}

/// One Ask. The last button is the default and the cancel choice, as Electron's dialogs are.
struct AskSheet: View {
  let ask: Ask
  let answer: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(ask.title).font(.headline)
      Text(ask.message)
      if let detail = ask.detail {
        Text(detail)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        ForEach(Array(ask.buttons.enumerated()), id: \.offset) { index, title in
          Button(title) { answer(index) }
            .keyboardShortcut(index == ask.buttons.count - 1 ? .defaultAction : nil)
        }
      }
    }
    .padding(20)
    .frame(width: 460)
    // Escape chooses the last button, Electron's cancelId. The last button holds Return, and a
    // button holds one shortcut, so a hidden button holds Escape. `onExitCommand` covers a
    // focused view; the queue ignores a second answer to the same Ask.
    .background {
      Button("") { answer(ask.buttons.count - 1) }
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .accessibilityHidden(true)
    }
    .onExitCommand { answer(ask.buttons.count - 1) }
    .interactiveDismissDisabled()
  }
}
