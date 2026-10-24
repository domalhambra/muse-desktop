import Foundation
import MuseBackend

extension Workspace {
  public func shouldPollPullRequest(showingChanges: Bool, now: Date) -> Bool {
    pullRequestError == nil
      && PullRequestRules.shouldPoll(
        showingChanges: showingChanges, hasPullRequest: pullRequest != nil, lastPoll: lastPullRequestPoll, now: now)
  }

  /// Reads the open conversation's PR. One read at a time; a reply for a conversation the person
  /// has left is dropped. A good read clears an earlier error, so the poll starts again.
  public func refreshPullRequest() async {
    guard let sessionId = view?.session.sessionId, !pullRequestInFlight else { return }
    pullRequestInFlight = true
    defer { pullRequestInFlight = false }
    let sequence = openSequence
    func current() -> Bool { sequence == openSequence && view?.session.sessionId == sessionId }
    lastPullRequestPoll = .now
    do {
      let found = try await client.pullRequest(sessionId: sessionId)
      guard current() else { return }
      pullRequest = found
      pullRequestError = nil
    } catch {
      guard current() else { return }
      pullRequestError = error.localizedDescription
    }
  }

  /// Reads the project's PRs. A reply for a project the person has left is dropped.
  public func loadChangeCards() async {
    let project = self.project
    guard !project.isEmpty else { return }
    do {
      let cards = try await client.pullRequests(project: project)
      guard project == self.project else { return }
      changeCards = cards
    } catch {
      guard project == self.project else { return }
      errorMessage = error.localizedDescription
    }
  }

  public func accept(_ pr: PullRequest) async {
    var merged = false
    await run { merged = try await self.client.mergePullRequest(project: self.project, number: pr.number) }
    guard merged else { return }
    showNotice("PR merged")
    await loadChangeCards()
    if view != nil { await refreshPullRequest() }
  }

  public func mergeWhenReady(_ pr: PullRequest) async {
    guard let sessionId = view?.session.sessionId else { return }
    await run { _ = try await self.client.mergeWhenReady(sessionId: sessionId, number: pr.number) }
  }

  /// Auto-fix sends the prompt to the conversation; Muse is the agent.
  public func autoFix(_ pr: PullRequest) async {
    guard let sessionId = view?.session.sessionId else { return }
    let prompt = PullRequestRules.autoFixPrompt(pr)
    await run { try await self.client.send(sessionId: sessionId, text: prompt, effort: self.effort, mode: .queue) }
  }

  /// A plain explanation in a side chat on the conversation that owns the branch, or a new
  /// conversation in the project when none does.
  public func askWhy(_ pr: PullRequest) async {
    let prompt = ChangeCardRules.askWhyPrompt(pr)
    if let owner = ChangeCardRules.owner(of: pr, worktrees: inspector.worktrees) {
      await open(owner)
      // A failed or overtaken open leaves another conversation shown: no side chat on that one.
      guard view?.session.sessionId == owner else { return }
      await openSideChat()
      await sendToSide(prompt)
    } else {
      startNew()
      draft = prompt
      _ = await send()
    }
  }
}
