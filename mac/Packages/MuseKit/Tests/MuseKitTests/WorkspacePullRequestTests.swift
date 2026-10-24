import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

private let pr = #"{"number":9,"title":"Usage","url":"u","state":"OPEN","isDraft":false,"reviewDecision":null,"mergeState":"CLEAN","baseRefName":"main","headRefName":"usage","mergedAt":null,"checks":[{"name":"e2e","state":"failing"}],"body":"","files":[],"live":false}"#

@MainActor @Test func acceptMergesAfterTheAskAndReloads() async throws {
  let lists = Counter()
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "pr-list": lists.next(); return [reply(id, "[\(pr)]")]
    case "pr-merge": return [reply(id, "true")]
    default: return [reply(id, "null")]
    }
  }
  workspace.project = "/p"
  await workspace.loadChangeCards()
  #expect(workspace.changeCards.map(\.number) == [9])
  await workspace.accept(workspace.changeCards[0])
  #expect(requests(backend).contains([.string("pr-merge"), .array([.string("/p"), .number(9)])]))
  #expect(lists.value == 2)
  #expect(workspace.notice == "PR merged")
}

@MainActor @Test func aGhFailureStopsThePoll() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "pr-status"
      ? [failure(id, "GitHub CLI is not signed in. Run gh auth login in Terminal.")] : [reply(id, "null")]
  }
  workspace.view = try decodeView(viewJSON(sessionJSON("s1")))
  await workspace.refreshPullRequest()
  #expect(workspace.pullRequestError == "GitHub CLI is not signed in. Run gh auth login in Terminal.")
  #expect(!workspace.shouldPollPullRequest(showingChanges: true, now: .now))
}

/// The id of the last request for `method`.
private func lastId(_ backend: ScriptedBackend, _ method: String) -> Int? {
  backend.messages.compactMap { message -> Int? in
    guard message["method"] == .string(method), case .number(let id)? = message["id"] else { return nil }
    return Int(id)
  }.last
}

private func count(_ backend: ScriptedBackend, _ method: String) -> Int {
  backend.messages.filter { $0["method"] == .string(method) }.count
}

@MainActor @Test func aPullRequestReadForAConversationLeftMidReadIsDropped() async throws {
  let (workspace, backend) = await makeWorkspace { method, args, id in
    switch method {
    case "pr-status": return []  // held: the test answers
    case "open":
      guard case .string(let sessionId)? = args.first else { return [] }
      return [reply(id, viewJSON(sessionJSON(sessionId)))]
    default: return [reply(id, "null")]
    }
  }
  workspace.view = try decodeView(viewJSON(sessionJSON("A")))
  let read = Task { await workspace.refreshPullRequest() }
  try await eventually { lastId(backend, "pr-status") != nil }
  await workspace.open("B")
  // The old read still runs, so B's first look waits for it.
  await workspace.refreshPullRequest()
  #expect(count(backend, "pr-status") == 1)
  backend.push(reply(lastId(backend, "pr-status")!, pr))
  await read.value
  #expect(workspace.pullRequest == nil && workspace.pullRequestError == nil)

  let failing = Task { await workspace.refreshPullRequest() }
  try await eventually { count(backend, "pr-status") == 2 }
  await workspace.open("C")
  backend.push(failure(lastId(backend, "pr-status")!, "gh failed"))
  await failing.value
  #expect(workspace.view?.session.sessionId == "C")
  #expect(workspace.pullRequest == nil && workspace.pullRequestError == nil)
}

@MainActor @Test func aGoodReadClearsTheErrorSoThePollStartsAgain() async throws {
  let calls = Counter()
  let (workspace, _) = await makeWorkspace { method, _, id in
    guard method == "pr-status" else { return [reply(id, "null")] }
    return calls.next() == 1 ? [failure(id, "gh failed")] : [reply(id, pr)]
  }
  workspace.view = try decodeView(viewJSON(sessionJSON("s1")))
  await workspace.refreshPullRequest()
  #expect(workspace.pullRequestError == "gh failed")
  await workspace.refreshPullRequest()
  #expect(workspace.pullRequestError == nil && workspace.pullRequest?.number == 9)
  #expect(
    workspace.shouldPollPullRequest(showingChanges: true, now: Date.now.addingTimeInterval(60)))
}

@MainActor @Test func askWhyOpensNoSideChatWhenTheOwnerDoesNotOpen() async throws {
  let worktrees =
    #"[{"path":"/p","branch":"refs/heads/main","isMain":true,"sessionIds":[]},{"path":"/p/.muse/worktrees/a","branch":"refs/heads/usage","isMain":false,"sessionIds":["s1"]}]"#
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "worktrees": [reply(id, worktrees)]
    case "git-status": [failure(id, "not read")]
    case "open": [failure(id, "That conversation is gone.")]
    default: [reply(id, "null")]
    }
  }
  workspace.view = try decodeView(viewJSON(sessionJSON("C")))
  await workspace.inspector.refresh()
  #expect(workspace.inspector.worktrees.count == 2)
  await workspace.askWhy(PullRequest(number: 9, title: "Usage", headRefName: "usage"))
  #expect(count(backend, "open") == 1)
  #expect(count(backend, "side-chat") == 0 && count(backend, "send") == 0)
  #expect(workspace.view?.session.sessionId == "C")
}

@MainActor @Test func changeCardsForAProjectLeftMidReadAreDropped() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "pr-list" ? [] : [reply(id, "null")]
  }
  workspace.project = "/p"
  let load = Task { await workspace.loadChangeCards() }
  try await eventually { lastId(backend, "pr-list") != nil }
  workspace.project = "/q"
  backend.push(reply(lastId(backend, "pr-list")!, "[\(pr)]"))
  await load.value
  #expect(workspace.changeCards.isEmpty)
}

@MainActor @Test func aProjectSwitchClearsTheCardsUntilTheNewLoadLands() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "pr-list": return [reply(id, "[\(pr)]")]
    case "pr-merge": return [reply(id, "true")]
    default: return [reply(id, "null")]
    }
  }
  workspace.project = "/p"
  await workspace.loadChangeCards()
  let stale = try #require(workspace.changeCards.first)
  #expect(workspace.changeCardsProject == "/p")
  workspace.project = "/q"
  #expect(workspace.changeCards.isEmpty)
  #expect(workspace.changeCardsProject == nil)
  // A card left from /p merges nothing in /q.
  await workspace.accept(stale)
  #expect(count(backend, "pr-merge") == 0)
  await workspace.loadChangeCards()
  #expect(workspace.changeCardsProject == "/q")
  #expect(workspace.changeCards.map(\.number) == [9])
}

@MainActor @Test func aDoubleAcceptSendsOneMerge() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "pr-list": return [reply(id, "[\(pr)]")]
    case "pr-merge": return []  // held: the second click arrives while the first runs
    default: return [reply(id, "null")]
    }
  }
  workspace.project = "/p"
  await workspace.loadChangeCards()
  let card = workspace.changeCards[0]
  let first = Task { await workspace.accept(card) }
  while count(backend, "pr-merge") == 0 { await Task.yield() }
  #expect(workspace.merging.contains(9))
  await workspace.accept(card)
  #expect(count(backend, "pr-merge") == 1)
  first.cancel()
}
