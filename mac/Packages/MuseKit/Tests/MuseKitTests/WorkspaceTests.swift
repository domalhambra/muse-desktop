import Foundation
import MuseBackend
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

@MainActor @Test func sessionsChangedRefreshesOnceAfterAPause() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "sessions" ? [reply(id, #"{"sessions":[],"nextCursor":null}"#)] : []
  }
  workspace.apply(.sessionsChanged)
  workspace.apply(.sessionsChanged)
  try await Task.sleep(for: .milliseconds(150))
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
