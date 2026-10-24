import Foundation
import MuseBackend

extension Workspace {
  public func shouldPollPullRequest(showingChanges: Bool, now: Date) -> Bool {
    pullRequestError == nil
      && PullRequestRules.shouldPoll(
        showingChanges: showingChanges, hasPullRequest: pullRequest != nil, lastPoll: lastPullRequestPoll, now: now)
  }

  public func refreshPullRequest() async {
    guard let sessionId = view?.session.sessionId else { return }
    lastPullRequestPoll = .now
    do {
      pullRequest = try await client.pullRequest(sessionId: sessionId)
    } catch {
      pullRequestError = error.localizedDescription
    }
  }

  public func loadChangeCards() async {
    guard !project.isEmpty else { return }
    do {
      changeCards = try await client.pullRequests(project: project)
    } catch {
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
      await openSideChat()
      await sendToSide(prompt)
    } else {
      startNew()
      draft = prompt
      _ = await send()
    }
  }
}
