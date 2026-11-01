import MuseBackend

// The Muse Code controls M6 adds: goals, fork, background work and skills.
extension Workspace {
  /// Runs a goal verb on the open conversation. The new value arrives in a `session` event.
  public func goal(_ verb: String, objective: String? = nil) async {
    guard let sessionId = view?.session.sessionId else { return }
    await run { try await self.runGoal(sessionId: sessionId, verb: verb, objective: objective) }
  }

  /// The sentence the backend gives Muse's `missing_goal` refusal (src/headless/plain-errors.ts).
  static let noGoal = "This conversation has no goal."

  /// Sends a goal verb. A reopened conversation can hold a goal another client cleared while this
  /// host was unsubscribed. When Muse says there is none, the strip goes, and the error still shows.
  func runGoal(sessionId: String, verb: String, objective: String? = nil) async throws {
    do {
      try await client.goal(sessionId: sessionId, verb: verb, objective: objective)
    } catch {
      if error.localizedDescription == Self.noGoal, view?.session.sessionId == sessionId {
        view?.goal = nil
      }
      throw error
    }
  }

  /// Forks through `turnId`, or through every completed turn when it is nil, then opens the fork.
  /// A second call while one runs does nothing.
  public func fork(fromTurn turnId: String? = nil) async {
    guard let sessionId = view?.session.sessionId, !forking else { return }
    forking = true
    defer { forking = false }
    await run { try await self.forkConversation(sessionId: sessionId, turnId: turnId) }
  }

  func forkConversation(sessionId: String, turnId: String?) async throws {
    let forked = try await client.fork(sessionId: sessionId, turnId: turnId)
    await open(forked.session.sessionId)
    showNotice("Forked. The original conversation is unchanged.")
  }

  /// Reads the background tasks. A reply for a conversation no longer open is dropped.
  public func loadTasks() async {
    guard let sessionId = view?.session.sessionId else {
      backgroundTasks = []
      return
    }
    await run {
      let tasks = try await self.client.tasks(sessionId: sessionId)
      if self.view?.session.sessionId == sessionId { self.backgroundTasks = tasks }
    }
  }

  /// Runs a background control, then reads the list again.
  public func controlTask(_ action: String, target: String? = nil) async {
    guard let sessionId = view?.session.sessionId else { return }
    await run {
      try await self.client.controlTask(sessionId: sessionId, action: action, target: target)
    }
    await loadTasks()
  }
}
