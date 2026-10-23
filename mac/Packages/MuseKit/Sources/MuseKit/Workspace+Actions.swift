import Foundation
import MuseBackend

// What the composer, the toolbar and the cards do. Electron's versions are in
// src/renderer/src/App.tsx (submit, changeModel, rename) and Transcript.tsx (the cards).
extension Workspace {
  /// Sends the draft. With no conversation open, it creates one in the current project first.
  public func send() async -> SendOutcome { await send(text: draft, from: draftKey) }

  /// Sends `text` and the attachment chips, written under the draft key `startKey`. A cancelled
  /// caller still waits for the backend's answer, and `submitting` stays true until it comes.
  func send(text: String, from startKey: String) async -> SendOutcome {
    // As Electron's submit: a message can be attachments alone.
    let chips = attachments
    guard !JSWhitespace.trim(text).isEmpty || !chips.isEmpty, !submitting else {
      return .notSent
    }
    if view == nil, project.isEmpty { return .needsProject }
    submitting = true
    sendingAttachmentIds = Set(chips.map(\.id))
    defer {
      submitting = false
      sendingAttachmentIds = []
    }
    // Taken now, as Electron's submit takes them when called: startNew resets the mode.
    let (mode, effort) = (self.mode, self.effort)
    let worktree = startInWorktree && canStartInWorktree
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
        // Its own task, like the send below: a cancelled caller still gets the conversation that
        // was created, so none is left behind and the next send does not create a second one.
        let client = self.client
        let (folder, model) = (project, modelId.isEmpty ? nil : modelId)
        let creating = Task.detached {
          try await client.create(project: folder, modelId: model, worktree: worktree)
        }
        current = try await creating.value
        // Show the new conversation, unless the person opened another one meanwhile.
        if sequence == openSequence, view == nil { view = current }
        if worktree {
          startInWorktree = false
          // As Electron: Muse runs this conversation in its new worktree, so follow it there.
          if sequence == openSequence, view?.session.sessionId == current.session.sessionId,
            let root = current.session.workspaceRoot
          {
            project = root
          }
        }
      }
      let sessionId = current.session.sessionId
      sentId = sessionId
      if sequence == openSequence, view?.session.sessionId == sessionId {
        // Show the message at once. The next session event replaces the whole list. Muse cannot
        // have echoed it yet, so there is no copy to look for; a check would only hide a repeated
        // reply such as "yes". With chips it shows the backend's display text, so a message of
        // chips alone is not an empty bubble.
        let id = "optimistic-\(UUID().uuidString)"
        shownId = id
        let display = chips.isEmpty ? text : ([text] + chips.map { "[Attached: \($0.name)]" }).joined(separator: "\n")
        view?.items.append(
          TranscriptItem(
            itemId: id, kind: "userMessage", status: "completed", text: text, displayText: display,
            recordedAt: Date.now.ISO8601Format()))
        previousStatus = view?.session.status
        view?.session.status = "running"
      }
      // Clear the draft only where it still holds what was sent.
      for key in [startKey, sessionId] where drafts[key] == text { drafts[key] = nil }
      // Its own detached task: cancelling the caller must not stop the wait, or a rejection that
      // comes later would leave the conversation shown as running. Detached, so the task inherits
      // neither the caller's cancellation nor the main actor: a caller cancelled before this call,
      // or during it, still sends the message and gets the conversation. The error path below is
      // then one main-actor hop away. `AppController.dropWorkspace()` assumes that order: a send
      // the stop cut off has put its text back before the event stream ends the backend. Nothing
      // enforces it.
      let client = self.client
      let ids = chips.map(\.id)
      let request = Task.detached {
        try await client.send(sessionId: sessionId, text: text, effort: effort, mode: mode, attachments: ids)
      }
      try await request.value
      // The backend forgot these ids. Chips added during the send stay.
      let sent = Set(ids)
      attachments.removeAll { sent.contains($0.id) }
      pastedFiles.forget(ids)
      return .sent
    } catch {
      let stillShown = sequence == openSequence && sentId != nil && view?.session.sessionId == sentId
      if stillShown {
        if let shownId { view?.items.removeAll { $0.itemId == shownId } }
        // Only while the status is still the one set above; a session event may have replaced it.
        if let previousStatus, view?.session.status == "running" { view?.session.status = previousStatus }
      }
      // The draft goes back where it was written: the conversation's own, or the new one's. The
      // chips stay, so the person can try again.
      let restoreKey = stillShown ? (sentId ?? startKey) : startKey
      if (drafts[restoreKey] ?? "").isEmpty { drafts[restoreKey] = text }
      errorMessage = error.localizedDescription
      return .notSent
    }
  }

  /// Sends the draft in a new conversation in a folder chosen in the open panel, after `send()`
  /// returned `.needsProject`. The draft moves to the new project, unless that project's new
  /// composer already holds a draft, which is kept; the text is then sent from where it was
  /// written. If the folder cannot be added, the draft stays where it was.
  public func send(addingProject folder: URL) async -> SendOutcome {
    let text = draft
    let startKey = draftKey
    guard await addProject(folder) else { return .notSent }
    guard draftKey != startKey, (drafts[draftKey] ?? "").isEmpty else {
      return await send(text: text, from: startKey)
    }
    drafts[draftKey] = text
    drafts[startKey] = nil
    return await send()
  }

  /// Stops the open conversation's turn.
  public func stop() async {
    guard let sessionId = view?.session.sessionId else { return }
    await run { try await self.client.cancel(sessionId) }
  }

  /// The inspector footer's Terminal: Terminal opens in the current project's folder.
  public func openProjectInTerminal() async {
    guard !project.isEmpty else { return }
    let project = project
    await run { try await self.client.openTerminal(project: project) }
  }

  /// The inspector footer's Muse Code: Terminal opens the full CLI in the current project's folder.
  public func openProjectInMuseCode() async {
    guard !project.isEmpty else { return }
    let project = project
    await run { try await self.client.openCLITerminal(project: project) }
  }

  /// The inspector footer's Finder: opens the project folder itself, as Electron's `reveal-project`.
  /// The app passes `NSWorkspace.shared.open`; it returns false when the folder did not open.
  public func revealProject(using open: (URL) -> Bool) {
    guard !project.isEmpty else { return }
    if !open(URL(fileURLWithPath: project, isDirectory: true)) {
      errorMessage = "mMac could not open \(project)."
    }
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
      if sequence == self.openSequence, self.view?.session.sessionId == sessionId { self.modelId = id }
    }
  }

  /// The open conversation's approval mode, or empty with none open. Muse owns it per session.
  public var approvalMode: String { view?.session.approvalMode?.mode ?? "" }

  /// Picks an approval mode for the open conversation. Muse applies it to its next action. The
  /// reply's effective mode shows at once, unless the person opened another conversation
  /// meanwhile; `approvalModeChanged` events keep it current after that.
  public func chooseApprovalMode(_ mode: String) async {
    guard let sessionId = view?.session.sessionId else { return }
    let sequence = openSequence
    await run {
      let effective = try await self.client.setApprovalMode(sessionId: sessionId, mode: mode)
      if sequence == self.openSequence, self.view?.session.sessionId == sessionId {
        self.view?.session.approvalMode = ApprovalModeState(mode: effective)
      }
    }
  }

  /// Saves preference fields. The backend's reply, and its `preferences` event, carry the whole set.
  @discardableResult
  public func save(_ patch: PreferencesPatch) async -> Bool {
    do {
      preferences = try await client.preferences(patch)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Saves the reasoning effort, which every later message uses.
  public func chooseEffort(_ effort: String) async {
    await save(PreferencesPatch(reasoningEffort: effort))
  }

  /// Saves a custom Muse Code path (empty for automatic detection), then reconnects.
  public func setCLIPath(_ path: String) async {
    // Electron trims the field before saving it.
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard await save(PreferencesPatch(cliPath: trimmed)) else { return }
    await reconnect()
  }

  /// Reconnects to Muse, then reopens the conversation last clicked, as Electron reopens `activeId`:
  /// the one opening, or else the one shown. Returns true when the connect call succeeded.
  @discardableResult
  public func reconnect() async -> Bool {
    await reconnect { self.errorMessage = $0 }
  }

  /// `reconnect()`, with the connect call's error going to `report`: the Settings window shows its
  /// own errors. An error reopening the conversation still shows here.
  func reconnect(reportingTo report: (String) -> Void) async -> Bool {
    do {
      let next = try await client.connect()
      apply(.connection(next))
      if next.isReady, let sessionId = openingSessionId ?? view?.session.sessionId {
        await open(sessionId, force: true)
      }
      return true
    } catch {
      report(error.localizedDescription)
      return false
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

  /// "Read stored output": reads a tool item's full output once. Opening another conversation or
  /// starting a new one clears what was read, and a reply that arrives after that is dropped.
  public func readOutput(_ item: TranscriptItem) async {
    guard let sessionId = view?.session.sessionId, storedOutput[item.itemId] == nil,
      !loadingOutput.contains(item.itemId)
    else { return }
    let sequence = openSequence
    loadingOutput.insert(item.itemId)
    // Always: a reopen of this same conversation moves the sequence on without clearing the set.
    defer { loadingOutput.remove(item.itemId) }
    await run {
      let output = try await self.client.readOutput(sessionId: sessionId, itemId: item.itemId)
      if sequence == self.openSequence { self.storedOutput[item.itemId] = output }
    }
  }

  /// "Ask Muse" on a diff: Electron's `onMentionDiff` sentence.
  public func askAboutChanges(_ path: String) {
    appendToDraft("Please review the changes in @\(path)\n")
  }

  /// "Ask Muse" on a file preview: Electron's `onMention` sentence, with the path as a JSON string.
  public func askAboutFile(_ path: String) {
    appendToDraft("Please look at the project file: \(Self.jsonString(path))\n")
  }

  /// Adds `text` on a new line when the draft has text, as Electron does, and focuses the composer.
  /// Nothing while a conversation opens, as a drop: the text would land in the old draft.
  func appendToDraft(_ text: String) {
    guard composerIsEditable else { return }
    let current = draft
    draft = current + (current.isEmpty ? "" : "\n") + text
    composerFocusRequest += 1
  }

  /// `JSON.stringify` of a string: quoted and escaped, slashes left alone.
  static func jsonString(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    guard let data = try? encoder.encode(value) else { return "\"\(value)\"" }
    return String(decoding: data, as: UTF8.self)
  }
}
