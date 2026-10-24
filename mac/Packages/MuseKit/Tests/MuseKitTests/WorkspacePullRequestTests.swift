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
