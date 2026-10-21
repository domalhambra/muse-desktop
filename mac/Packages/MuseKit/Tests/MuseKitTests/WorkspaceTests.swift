import Foundation
import MuseBackend
import Observation
import Testing
@testable import MuseKit

@MainActor @Test func historyFollowsEveryPage() async throws {
  let (workspace, backend) = await makeWorkspace { method, args, id in
    guard method == "sessions" else { return [] }
    if args.isEmpty {
      return [reply(id, #"{"sessions":[\#(sessionJSON("a")),\#(sessionJSON("b"))],"nextCursor":"c2"}"#)]
    }
    return [reply(id, #"{"sessions":[\#(sessionJSON("b")),\#(sessionJSON("c"))],"nextCursor":null}"#)]
  }
  await workspace.refreshSessions()
  #expect(workspace.sessions.map(\.sessionId) == ["a", "b", "c"])
  #expect(workspace.historyError == nil)
  #expect(requests(backend) == [["sessions", []], ["sessions", ["c2"]]])
}

@MainActor @Test func aRepeatedCursorStopsWithAnError() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "sessions" ? [reply(id, #"{"sessions":[],"nextCursor":"c1"}"#)] : []
  }
  await workspace.refreshSessions()
  #expect(workspace.historyError == "Muse returned a repeated history cursor. Reconnect to refresh history.")
}

@MainActor @Test func aLateOpenReplyIsIgnored() async throws {
  let (workspace, backend) = await makeWorkspace { method, args, id in
    guard method == "open", args.first == "s2" else { return [] }
    return [reply(id, viewJSON(sessionJSON("s2", root: "/q")))]
  }
  let first = Task { await workspace.open("s1") }
  try await eventually { backend.messages.contains { $0["method"] == "open" } }
  await workspace.open("s2")
  #expect(workspace.view?.session.sessionId == "s2")
  #expect(workspace.project == "/q")
  guard case .number(let lateId)? = backend.messages.first(where: { $0["method"] == "open" })?["id"] else {
    Issue.record("No first open request")
    return
  }
  backend.push(reply(Int(lateId), viewJSON(sessionJSON("s1"))))
  await first.value
  #expect(workspace.view?.session.sessionId == "s2")
}

@MainActor @Test func sessionEventsUpdateTheOpenViewAndTheHistory() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "sessions": [reply(id, #"{"sessions":[\#(sessionJSON("s1")),\#(sessionJSON("s2"))],"nextCursor":null}"#)]
    case "open": [reply(id, viewJSON(sessionJSON("s1")))]
    default: []
    }
  }
  await workspace.refreshSessions()
  await workspace.open("s1")
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s1", status: "running")))))
  #expect(workspace.view?.session.status == "running")
  #expect(workspace.sessions[0].status == "running")
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s2", status: "running")))))
  #expect(workspace.view?.session.sessionId == "s1")
  #expect(workspace.sessions[1].status == "running")
}

@MainActor @Test func historyKeepsANameTheListOmits() async throws {
  // session/list can lag a rename for a live conversation and leave out its name.
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "sessions" ? [reply(id, #"{"sessions":[\#(sessionJSON("s1"))],"nextCursor":null}"#)] : []
  }
  await workspace.refreshSessions()
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s1", name: "renamed")))))
  #expect(workspace.sessions[0].name == "renamed")
  await workspace.refreshSessions()
  #expect(workspace.sessions[0].name == "renamed")
}

@MainActor @Test func historyKeepsATitleAndPromptTheListOmits() async throws {
  // Just after a turn, session/list lags and returns the row without its title and first prompt.
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "sessions" ? [reply(id, #"{"sessions":[\#(sessionJSON("s1"))],"nextCursor":null}"#)] : []
  }
  await workspace.refreshSessions()
  workspace.apply(
    .session(try decodeView(viewJSON(sessionJSON("s1", title: "Fix it", firstUserPrompt: "Fix the bug")))))
  #expect(workspace.sessions[0].title == "Fix it")
  await workspace.refreshSessions()
  #expect(workspace.sessions[0].title == "Fix it")
  #expect(workspace.sessions[0].firstUserPrompt == "Fix the bug")
  #expect(SessionTitle.of(workspace.sessions[0]) == "Fix it")
}

@MainActor @Test func historyKeepsTheOpenConversationsPromptForANewRow() async throws {
  // A new conversation has no row until a refresh, so a session event cannot update one. The open
  // view still holds the prompt.
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "open": [reply(id, viewJSON(sessionJSON("s1", firstUserPrompt: "Fix the bug")))]
    case "sessions": [reply(id, #"{"sessions":[\#(sessionJSON("s1"))],"nextCursor":null}"#)]
    default: []
    }
  }
  await workspace.open("s1")
  await workspace.refreshSessions()
  #expect(workspace.sessions[0].firstUserPrompt == "Fix the bug")
}

@MainActor @Test func aTitleOrPromptFromTheListReplacesTheKnownOne() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "open": [reply(id, viewJSON(sessionJSON("s1", title: "Older", firstUserPrompt: "Older prompt")))]
    case "sessions":
      [reply(id, #"{"sessions":[\#(sessionJSON("s1", title: "Newer", firstUserPrompt: "Newer prompt"))],"nextCursor":null}"#)]
    default: []
    }
  }
  await workspace.open("s1")
  await workspace.refreshSessions()
  #expect(workspace.sessions[0].title == "Newer")
  #expect(workspace.sessions[0].firstUserPrompt == "Newer prompt")
}

@MainActor @Test func sessionsChangedRefreshesOnceAfterAPause() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "sessions" ? [reply(id, #"{"sessions":[],"nextCursor":null}"#)] : []
  }
  workspace.apply(.sessionsChanged)
  workspace.apply(.sessionsChanged)
  try await eventually { backend.messages.filter { $0["method"] == "sessions" }.count == 1 }
  // Longer than the pause, so a second refresh would have started by now.
  try await Task.sleep(for: .milliseconds(50))
  #expect(backend.messages.filter { $0["method"] == "sessions" }.count == 1)
}

@MainActor @Test func addingAProjectSelectsItsRealPath() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "add-project" ? [reply(id, #""/real/project""#)] : []
  }
  #expect(await workspace.addProject(URL(fileURLWithPath: "/tmp/link")))
  #expect(workspace.project == "/real/project")
  #expect(workspace.view == nil)
  #expect(requests(backend) == [["add-project", ["/tmp/link"]]])
  workspace.selectProject("")
  #expect(workspace.project == "")
}

@MainActor @Test func becomingReadyLoadsHistoryAndModels() async throws {
  let (workspace, backend) = await makeWorkspace(status: ConnectionStatus(state: "connecting")) { method, _, id in
    switch method {
    case "sessions": [reply(id, #"{"sessions":[],"nextCursor":null}"#)]
    case "models": [reply(id, "[]")]
    default: []
    }
  }
  workspace.apply(.connection(ConnectionStatus(state: "ready", version: "1.4.11")))
  try await eventually { backend.messages.contains { $0["method"] == "models" } }
  #expect(workspace.isConnected)
  #expect(backend.messages.contains { $0["method"] == "sessions" })
}

@MainActor @Test func preferencesEventsReplaceThePreferences() async throws {
  let (workspace, _) = await makeWorkspace()
  workspace.apply(.preferences(Preferences(recentProjects: ["/x"], reasoningEffort: "max")))
  #expect(workspace.effort == "max")
  #expect(workspace.preferences.recentProjects == ["/x"])
}

@MainActor @Test func startingNewDropsAnOpenStillInFlight() async throws {
  // Electron's startNew bumps the open sequence, so a reply after New does not reopen it.
  let (workspace, backend) = await makeWorkspace()
  let opening = Task { await workspace.open("s1") }
  try await eventually { backend.messages.contains { $0["method"] == "open" } }
  workspace.startNew()
  #expect(workspace.openingSessionId == nil)
  guard case .number(let id)? = backend.messages.first(where: { $0["method"] == "open" })?["id"] else {
    Issue.record("No open request")
    return
  }
  backend.push(reply(Int(id), viewJSON(sessionJSON("s1", root: "/q"))))
  await opening.value
  #expect(workspace.view == nil)
  #expect(workspace.project == "/p")
}

@MainActor @Test func aRenameDuringARefreshKeepsItsName() async throws {
  // The second page waits until the test pushes it, so the rename lands between the pages.
  let (workspace, backend) = await makeWorkspace { method, args, id in
    guard method == "sessions", args.isEmpty else { return [] }
    return [reply(id, #"{"sessions":[\#(sessionJSON("s1"))],"nextCursor":"c2"}"#)]
  }
  let refreshing = Task { await workspace.refreshSessions() }
  try await eventually { backend.messages.filter { $0["method"] == "sessions" }.count == 2 }
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s1", name: "renamed")))))
  guard case .number(let id)? = backend.messages.last(where: { $0["method"] == "sessions" })?["id"] else {
    Issue.record("No second page request")
    return
  }
  backend.push(reply(Int(id), #"{"sessions":[\#(sessionJSON("s1"))],"nextCursor":null}"#))
  await refreshing.value
  #expect(workspace.sessions.map(\.name) == ["renamed"])
}

@MainActor @Test func aSecondSessionsChangedDoesNotCancelARunningRefresh() async throws {
  // Muse answers only when the test pushes a reply, so the first refresh is still loading when the
  // second event comes. Its reply lands during the second pause, before the second refresh starts.
  let (workspace, backend) = await makeWorkspace(refreshDebounce: .milliseconds(100))
  workspace.apply(.sessionsChanged)
  try await eventually { backend.messages.filter { $0["method"] == "sessions" }.count == 1 }
  workspace.apply(.sessionsChanged)
  guard case .number(let id)? = backend.messages.first(where: { $0["method"] == "sessions" })?["id"] else {
    Issue.record("No first refresh request")
    return
  }
  backend.push(reply(Int(id), #"{"sessions":[\#(sessionJSON("s1"))],"nextCursor":null}"#))
  // A cancelled first refresh would never write its reply.
  try await eventually { workspace.sessions.map(\.sessionId) == ["s1"] }
  try await eventually { backend.messages.filter { $0["method"] == "sessions" }.count == 2 }
  try await Task.sleep(for: .milliseconds(20))
  #expect(workspace.sessions.map(\.sessionId) == ["s1"])
  #expect(workspace.historyError == nil)
}

@MainActor @Test func aLaterPageKeepsItsKnownName() async throws {
  let (workspace, _) = await makeWorkspace { method, args, id in
    guard method == "sessions" else { return [] }
    if args.isEmpty { return [reply(id, #"{"sessions":[\#(sessionJSON("s1"))],"nextCursor":"c2"}"#)] }
    return [reply(id, #"{"sessions":[\#(sessionJSON("s2"))],"nextCursor":null}"#)]
  }
  await workspace.refreshSessions()
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s2", name: "renamed")))))
  #expect(workspace.sessions.map(\.name) == [nil, "renamed"])
  await workspace.refreshSessions()
  #expect(workspace.sessions.map(\.name) == [nil, "renamed"])
}

@MainActor @Test func clickingTheShownConversationWhileAnotherOpensKeepsIt() async throws {
  // The last click wins: s2's late reply must not replace s1.
  let (workspace, backend) = await makeWorkspace { method, args, id in
    method == "open" && args.first == "s1" ? [reply(id, viewJSON(sessionJSON("s1")))] : []
  }
  await workspace.open("s1")
  let second = Task { await workspace.open("s2") }
  try await eventually { backend.messages.filter { $0["method"] == "open" }.count == 2 }
  await workspace.open("s1")
  #expect(workspace.openingSessionId == nil)
  guard case .number(let id)? = backend.messages.last(where: { $0["method"] == "open" })?["id"] else {
    Issue.record("No second open request")
    return
  }
  backend.push(reply(Int(id), viewJSON(sessionJSON("s2"))))
  await second.value
  #expect(workspace.view?.session.sessionId == "s1")
}

@MainActor @Test func openingAFolderlessConversationShowsAllProjects() async throws {
  let noRoot = #"{"sessionId":"s9","workspaceRoot":null,"createdAt":"2026-10-21T00:00:00Z","updatedAt":"2026-10-21T10:00:00Z","status":"idle","activeTurnId":null,"modelId":null,"turnCount":0}"#
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "sessions": [reply(id, #"{"sessions":[\#(noRoot)],"nextCursor":null}"#)]
    case "open": [reply(id, viewJSON(noRoot))]
    default: []
    }
  }
  await workspace.refreshSessions()
  await workspace.open("s9")
  #expect(workspace.project == "")
  #expect(workspace.sections.flatMap(\.sessions).map(\.sessionId).contains("s9"))
}

@MainActor @Test func openingAConversationSelectsItsModel() async throws {
  let (workspace, _) = await makeWorkspace { method, args, id in
    guard method == "open" else { return [] }
    let model: String? = args.first == "s1" ? "m-large" : nil
    return [reply(id, viewJSON(sessionJSON(args.first == "s1" ? "s1" : "s2", modelId: model)))]
  }
  await workspace.open("s1")
  #expect(workspace.modelId == "m-large")
  await workspace.open("s2")
  #expect(workspace.modelId == "")
}

@MainActor @Test func selectingAProjectClosesTheOpenConversation() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "open" ? [reply(id, viewJSON(sessionJSON("s1")))] : []
  }
  await workspace.open("s1")
  #expect(workspace.view != nil)
  workspace.selectProject("/other")
  #expect(workspace.view == nil)
  #expect(workspace.project == "/other")
}

@MainActor @Test func aRefreshClearsTheLastHistoryErrorWhenItStarts() async throws {
  // The first refresh fails; the second gets no answer until the test pushes one.
  let calls = Counter()
  let (workspace, backend) = await makeWorkspace { method, _, id in
    guard method == "sessions" else { return [] }
    return calls.next() == 1 ? [failure(id, "boom")] : []
  }
  await workspace.refreshSessions()
  #expect(workspace.historyError == "boom")
  let again = Task { await workspace.refreshSessions() }
  try await eventually { backend.messages.filter { $0["method"] == "sessions" }.count == 2 }
  #expect(workspace.historyError == nil)
  guard case .number(let id)? = backend.messages.last(where: { $0["method"] == "sessions" })?["id"] else {
    Issue.record("No second refresh request")
    return
  }
  backend.push(reply(Int(id), #"{"sessions":[],"nextCursor":null}"#))
  await again.value
  #expect(workspace.historyError == nil)
}

@MainActor @Test func historyShowsLoadingOnlyBeforeTheFirstSuccess() async throws {
  // Every refresh after the first gets no answer until the test pushes one.
  let calls = Counter()
  let (workspace, backend) = await makeWorkspace { method, _, id in
    guard method == "sessions" else { return [] }
    return calls.next() == 1 ? [reply(id, #"{"sessions":[],"nextCursor":null}"#)] : []
  }
  await workspace.refreshSessions()
  #expect(workspace.historyLoading == false)
  let again = Task { await workspace.refreshSessions() }
  try await eventually { backend.messages.filter { $0["method"] == "sessions" }.count == 2 }
  #expect(workspace.historyLoading == false)
  guard case .number(let id)? = backend.messages.last(where: { $0["method"] == "sessions" })?["id"] else {
    Issue.record("No second refresh request")
    return
  }
  backend.push(reply(Int(id), #"{"sessions":[],"nextCursor":null}"#))
  await again.value
}

@MainActor @Test func anUnchangedSessionEventLeavesTheHistoryUntouched() async throws {
  // Every streamed update sends a session event; the sidebar redraws only when a row changes.
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "sessions" ? [reply(id, #"{"sessions":[\#(sessionJSON("s1"))],"nextCursor":null}"#)] : []
  }
  await workspace.refreshSessions()
  let changes = Counter()
  withObservationTracking { _ = workspace.sessions } onChange: { changes.next() }
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s1")))))
  #expect(changes.value == 0)
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s1", status: "running")))))
  #expect(changes.value == 1)
}
