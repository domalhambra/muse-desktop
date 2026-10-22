import MuseBackend

/// Asks from the backend, shown one at a time as alert sheets, in the order they came.
@MainActor
final class AskQueue {
  /// Bumped by `cancelAll`. A backend's Asks carry the generation it started in.
  private(set) var generation = 0
  /// The Ask on screen, so `cancelAll` can close it.
  private var showing: AlertToken?
  /// Ends once every earlier Ask is answered.
  private var last: Task<Void, Never>?

  /// Shows `ask` when every earlier one is answered, and returns the chosen button's index.
  /// An Ask from an older generation, whose backend the queue was cancelled for, returns -1.
  func present(_ ask: Ask, generation: Int) async -> Int {
    guard generation == self.generation else { return -1 }
    let previous = last
    let turn = Task { @MainActor [weak self] () -> Int in
      await previous?.value
      guard let self, generation == self.generation else { return -1 }
      let token = AlertToken()
      showing = token
      defer { if showing === token { showing = nil } }
      return await SheetAlert.present(
        title: ask.title, message: ask.message, detail: ask.detail, buttons: ask.buttons, token: token)
    }
    last = Task { _ = await turn.value }
    return await turn.value
  }

  /// Answers every waiting Ask with -1, the cancel choice. Used when the backend stops.
  func cancelAll() {
    generation += 1
    showing?.close()
    showing = nil
  }
}
