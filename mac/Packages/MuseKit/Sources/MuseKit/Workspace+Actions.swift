import Foundation
import MuseBackend

// What the composer, the toolbar and the cards do. Electron's versions are in
// src/renderer/src/App.tsx (submit, changeModel, rename) and Transcript.tsx (the cards).
extension Workspace {
  /// Sends the draft. With no conversation open, it creates one in the current project first.
  public func send() async -> SendOutcome {
    let text = draft
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !submitting else {
      return .notSent
    }
    if view == nil, project.isEmpty { return .needsProject }
    submitting = true
    defer { submitting = false }
    let startKey = draftKey
    // Taken now, as Electron's submit takes them when called: startNew resets the mode.
    let (mode, effort) = (self.mode, self.effort)
    // As Electron's submit: the view changes only while the person stays on this conversation.
    let sequence = openSequence
    var sentId: String?
    var shownId: String?
    var previousStatus: String?
    do {
      let current: SessionView
      if let view {
        current = view
      } else {
        current = try await client.create(project: project, modelId: modelId.isEmpty ? nil : modelId)
        // Show the new conversation, unless the person opened another one meanwhile.
        if sequence == openSequence, view == nil { view = current }
      }
      let sessionId = current.session.sessionId
      sentId = sessionId
      if sequence == openSequence, view?.session.sessionId == sessionId {
        // Show the message at once. The next session event replaces the whole list.
        if view?.items.contains(where: { $0.kind == "userMessage" && ($0.text == text || $0.displayText == text) })
          != true
        {
          let id = "optimistic-\(UUID().uuidString)"
          shownId = id
          view?.items.append(
            TranscriptItem(
              itemId: id, kind: "userMessage", status: "completed", text: text, displayText: text,
              recordedAt: Date.now.ISO8601Format()))
        }
        previousStatus = view?.session.status
        view?.session.status = "running"
      }
      // Clear the draft only where it still holds what was sent.
      for key in [startKey, sessionId] where drafts[key] == text { drafts[key] = nil }
      try await client.send(sessionId: sessionId, text: text, effort: effort, mode: mode)
      return .sent
    } catch {
      let stillShown = sequence == openSequence && sentId != nil && view?.session.sessionId == sentId
      if stillShown {
        if let shownId { view?.items.removeAll { $0.itemId == shownId } }
        // Only while the status is still the one set above; a session event may have replaced it.
        if let previousStatus, view?.session.status == "running" { view?.session.status = previousStatus }
      }
      // The draft goes back where it was written: the conversation's own, or the new one's.
      let restoreKey = stillShown ? (sentId ?? startKey) : startKey
      if (drafts[restoreKey] ?? "").isEmpty { drafts[restoreKey] = text }
      errorMessage = error.localizedDescription
      return .notSent
    }
  }

  /// Stops the open conversation's turn.
  public func stop() async {
    guard let sessionId = view?.session.sessionId else { return }
    await run { try await self.client.cancel(sessionId) }
  }

  /// Renames the open conversation. Returns false for a blank name or a failure.
  public func rename(_ name: String) async -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let sessionId = view?.session.sessionId, !trimmed.isEmpty else { return false }
    do {
      try await client.rename(sessionId: sessionId, name: trimmed)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Chooses the model: for the next new conversation, or for the open one through the backend.
  public func chooseModel(_ id: String) async {
    guard let sessionId = view?.session.sessionId else {
      modelId = id
      return
    }
    // As Electron's setModel: a reply after the person opened another conversation is not applied.
    let sequence = openSequence
    await run {
      try await self.client.setModel(sessionId: sessionId, modelId: id)
      if sequence == self.openSequence { self.modelId = id }
    }
  }

  /// Saves the reasoning effort, which every later message uses.
  public func chooseEffort(_ effort: String) async {
    await run { self.preferences = try await self.client.preferences(PreferencesPatch(reasoningEffort: effort)) }
  }

  /// Saves a custom Muse Code path (empty for automatic detection), then reconnects.
  public func setCLIPath(_ path: String) async {
    do {
      preferences = try await client.preferences(PreferencesPatch(cliPath: path))
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    await reconnect()
  }

  /// Reconnects to Muse, then reopens the open conversation, as Electron does.
  public func reconnect() async {
    do {
      let next = try await client.connect()
      apply(.connection(next))
      if next.isReady, let sessionId = view?.session.sessionId { await open(sessionId, force: true) }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Answers an approval card. A second click while the first runs does nothing, as Electron
  /// disables the card's buttons.
  public func approve(_ approval: Approval, choice: Approval.Choice) async {
    guard decidingApprovals.insert(approval.approvalId).inserted else { return }
    defer { decidingApprovals.remove(approval.approvalId) }
    await run {
      try await self.client.approve(
        sessionId: approval.sessionId, approvalId: approval.approvalId, choiceId: choice.choiceId)
    }
  }

  public func answer(_ question: UserQuestion, answers: [QuestionAnswer]) async {
    guard answeringQuestions.insert(question.userInputId).inserted else { return }
    defer { answeringQuestions.remove(question.userInputId) }
    await run {
      try await self.client.answer(
        sessionId: question.sessionId, userInputId: question.userInputId, answers: answers)
    }
  }

  /// "Skip question": cancels the question, and Muse continues without an answer.
  public func skip(_ question: UserQuestion) async {
    guard answeringQuestions.insert(question.userInputId).inserted else { return }
    defer { answeringQuestions.remove(question.userInputId) }
    await run {
      try await self.client.cancelQuestion(sessionId: question.sessionId, userInputId: question.userInputId)
    }
  }

  /// "Read stored output": reads a tool item's full output once.
  public func readOutput(_ item: TranscriptItem) async {
    guard let sessionId = view?.session.sessionId, storedOutput[item.itemId] == nil,
      !loadingOutput.contains(item.itemId)
    else { return }
    loadingOutput.insert(item.itemId)
    defer { loadingOutput.remove(item.itemId) }
    await run {
      self.storedOutput[item.itemId] = try await self.client.readOutput(sessionId: sessionId, itemId: item.itemId)
    }
  }
}
